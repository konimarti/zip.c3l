module archive::zip;

import std::io, std::time, std::hash::crc32, std::collections::list;
import compress::flate;

<*
 ZipReader stores the metadata for a Zip archive. Metadata includes the
 relevant offset to seek the local file header (stored in the ZipEntries),
 central directory headers, and end of record.
*>
struct ZipReader (Printable)
{
	Allocator  allocator;
	InStream   file;     // Wrapped Zip archive file.
	ZipEntry[] entries;  // File information in Zip archive.
	ulong      end_record_offset;
	ulong      central_directory_offset;
	bool       is_zip64; // Indicate ZIP64 file format if true.
}

fn ZipReader* ZipReader.tinit(&self, InStream r) @inline => self.init(tmem, r);
fn ZipReader* ZipReader.init(&self, Allocator allocator, InStream r)
{
	*self = { .allocator = allocator, .file = r };
	return self;
}

fn ZipReader*? ZipReader.parse(&self) => @pool()
{
	ZipLocalFileHeader   local_header;
	ZipCentralFileHeader central_header;
	ZipDataDescriptor    data_descriptor;
	ZipEndRecord         end_record;

	defer catch self.free();

	if (try loc = find_signature_r(self.file, SIGNATURE_END))
	{
		self.end_record_offset = loc;
	}
	else
	{
		// Fallback: End Record not found, scan for Local File Header.
		// TODO: Check for Central Directory header as another fallback option?
		List {ZipEntry} entries;
		entries.tinit();

		self.file.seek(0, Seek.SET)!;
		while (try loc = find_next_signature(self.file, SIGNATURE_LOCAL))
		{

			self.file.seek(loc, Seek.SET)!;
			local_header.unpack(tmem, self.file)!;

			// Hack together an (incomplete) Central Directory File header
			central_header.filename        = local_header.filename.copy(self.allocator);
			central_header.filename_len    = local_header.filename_len;
			central_header.extra           = local_header.extra.copy(self.allocator);
			central_header.extra_len       = local_header.extra_len;
			central_header.compress_size   = local_header.compress_size;
			central_header.uncompress_size = local_header.uncompress_size;
			central_header.compress_method = local_header.compress_method;
			central_header.crc32           = local_header.crc32;
			central_header.rel_offset      = (uint)loc;

			ZipEntry entry;
			entry.init_with_headers(self.allocator, central_header, local_header)!;
			entries.push(entry);
		}

		self.entries = entries.to_array(self.allocator);

		return self;
	}

	self.file.seek(self.end_record_offset, Seek.SET)!;
	end_record.unpack(tmem, self.file)!;

	self.central_directory_offset = end_record.rel_offset;

	usz offset   = end_record.rel_offset;
	usz nrecords = end_record.tot_nr_records;

	self.is_zip64 = offset == 0xFF_FF_FF_FF || nrecords == 0xFF_FF;

	if (self.is_zip64)
	{
		Zip64EndLocator locator;
		Zip64EndRecord  record_z64;

		// Find the Zip64 Locator.
		usz loc = find_signature_r(self.file, SIGNATURE_LOCATOR_ZIP64)!;
		self.file.seek(loc, Seek.SET)!;
		locator.unpack(self.file)!;

		// Parse Zip64 End Record.
		self.file.seek(locator.rel_offset, Seek.SET)!;
		record_z64.unpack(self.file)!;

		self.central_directory_offset = record_z64.rel_offset;
		offset   = record_z64.rel_offset;
		nrecords = record_z64.tot_nr_records;
	}

	self.entries = allocator::new_array(self.allocator, ZipEntry, nrecords);

	// Read file headers.
	foreach (&zip_file : self.entries)
	{
		self.file.seek(offset, Seek.SET)!;
		central_header.unpack(tmem, self.file)!;
		offset = self.file.seek(0, Seek.CURSOR)!;

		self.file.seek(central_header.rel_offset, Seek.SET)!;

		local_header.unpack(tmem, self.file)!;
		if (central_header.flag.streaming)
		{
			// TODO: Write a unit test for a streamed Zip archive.

			// When we are streaming, we dont have the
			// compress_size available. What we need to do is scan
			// for the next local header file and use the central
			// directory offset as an indicator for EOF. The
			// data descriptor is then "read" backwards from the
			// next locator or the central directory offset.
			if (try loc = find_next_signature(self.file, SIGNATURE_LOCAL))
			{
				self.file.seek(self.is_zip64 ? -20 : -12, Seek.CURSOR)!;
			}
			else
			{
				// `find_next_signature` threw pobably an EOF
				// error; so we assume we are looking at the
				// last file that ends with central directory.
				self.file.seek(self.central_directory_offset + (self.is_zip64 ? -20 : -12), Seek.SET)!;
			}
			data_descriptor.unpack(self.file, self.is_zip64)!;
		}

		zip_file.init_with_headers(self.allocator, central_header, local_header, data_descriptor)!;
	}
	return self;
}

fn void ZipReader.free(&self)
{
	if (!self.allocator) return;
	foreach (&entry : self.entries) entry.free();
	allocator::free(self.allocator, self.entries);
	*self = {};
}

fn usz? ZipReader.to_format(&self, Formatter *f) @dynamic
{
	usz n;
	double tot_comp, tot_uncomp;
	foreach (i, entry : self)
	{
		tot_comp += entry.compress_size;
		tot_uncomp += entry.uncompress_size;
		n += f.printf("%04x %d %8d %s %s %s\n",
			entry.rel_offset, entry.compress_method, entry.uncompress_size,
			entry.date, entry.time, entry.filename)!;
	}
	n += f.printf("%d files, %d bytes uncompressed, %d bytes compressed: %4.1f%%\n",
		self.len(), tot_uncomp, tot_comp,
		tot_uncomp > 0.0 ? 100.0 * (1.0 - tot_comp / tot_uncomp): 0.0)!;
	return n;
}

fn usz ZipReader.len(&self) @operator(len) => self.entries.len;

fn ZipEntry ZipReader.get(&self, usz index) @operator([]) => self.entries[index];

<*
 ZipTime is in the MS-DOS format and is a 16-bit packed value representing the
 time of the day.

  	Bits   0-4: Seconds divided by 2 (0-29)
  	Bits  5-10: Minutes (0-59)
  	Bits 11-15: Hours (0-23)
*>
struct ZipTime (Printable)
{
	union
	{
		bitstruct : ushort
		{
			char halfsec : 0 .. 4;
			char minutes : 5 .. 10;
			char hours   : 11 .. 15;
		}
		ushort last_mod_time;
	}
}

fn void ZipTime.init(&self, DateTime t)
{
	*self = { .hours = t.hour, .minutes = t.min, .halfsec = t.sec / 2 };
}

fn usz? ZipTime.to_format(&self, Formatter *f) @dynamic
{
	return f.printf("%02d:%02d:%02d", self.hours, self.minutes, self.halfsec * 2);
}

<*
 ZipDate is in the MS-DOS format which is a 16-bit packed value that specifies
 the day, month, and year.

  	Bits  0-4: Day of the month (0 - 31)
  	Bits  5-8: Month (1=Jan, 2=Feb, and so on)
  	Bits 9-15: Year offset from 1980 (add 1980 to get actual year)
*>
struct ZipDate (Printable)
{
	union
	{
		bitstruct : ushort
		{
			char day   : 0 .. 4;
			char month : 5 .. 8;
			char year  : 9 .. 15;
		}
		ushort last_mod_date;
	}
}

fn void ZipDate.init(&self, DateTime t)
{
	*self = { .year = (char)(t.year - 1980), .month = t.month.ordinal + 1, .day = t.day };
}

fn usz? ZipDate.to_format(&self, Formatter *f) @dynamic
{
	return f.printf("%04d-%02d-%02d", self.year + 1980, self.month, self.day);
}

<*
 ZipEntry contains the metadata for a file entry in the zip archive.
*>
struct ZipEntry
{
	Allocator allocator;

	// Data from Local File Header
	ushort    version_min;
	ZipFlag   flag;
	ushort    compress_method;
	ZipTime   time;
	ZipDate   date;
	uint      crc32;
	ulong     compress_size;
	ulong     uncompress_size;
	String    filename;
	String    extra;

	// Data from Central Directory Header
	ushort    version_used;
	ushort    internal_attr;
	uint      external_attr;
	ulong     rel_offset; 		// offset to begin of Local File Header
	ulong     file_offset; 		// offset to beginn of compressed file data
}

fn ZipEntry*? ZipEntry.init_with_headers(&self, Allocator allocator,
	ZipCentralFileHeader central_header, ZipLocalFileHeader local_header,
	ZipDataDescriptor data_descriptor = {})
{
	self.allocator = allocator;

	// Data from Local File Header
	self.version_min        = local_header.version_min;
	self.flag               = local_header.flag;
	self.compress_method    = local_header.compress_method;
	self.time.last_mod_time = local_header.last_mod_time;
	self.date.last_mod_date = local_header.last_mod_date;
	self.crc32              = local_header.crc32;
	self.compress_size      = local_header.compress_size;
	self.uncompress_size    = local_header.uncompress_size;
	self.extra              = local_header.extra.copy(allocator);

	// Obtain filename
	if (self.flag.language)
	{
		self.filename = local_header.filename.copy(allocator);;
	}
	else if (try block = find_extra_header(self.extra, UNICODE_PATH_HEADER))
	{
		UnicodePathExtraField unicode_extra;
		unicode_extra.unpack(block)!;
		self.filename = unicode_extra.filename.copy(allocator);
	}
	else
	{
		self.filename = local_header.filename.copy(allocator);
	}

	// Data from Central Directory Header
	self.version_used  = central_header.version_used;
	self.internal_attr = central_header.internal_attr;
	self.external_attr = central_header.external_attr;
	self.rel_offset    = central_header.rel_offset;
	self.file_offset   = (ulong)central_header.rel_offset + 30 + local_header.filename_len + local_header.extra_len;

	// Check for ZIP64 and replace the corresponding field.
	if (self.is_zip64())
	{
		if (try block = find_extra_header(self.extra, ZIP64_EXTRA_HEADER))
		{
			Zip64ExtraField zip64_extra;
			zip64_extra.unpack(block)!;
			if (self.compress_size   == 0xFF_FF_FF_FF) self.compress_size   = zip64_extra.compress_size;
			if (self.uncompress_size == 0xFF_FF_FF_FF) self.uncompress_size = zip64_extra.uncompress_size;
			if (self.rel_offset      == 0xFF_FF_FF_FF) self.rel_offset      = zip64_extra.rel_offset;
		}
	}

	// Data from Data Descriptor (if needed).
	if (self.flag.streaming)
	{
		self.crc32           = data_descriptor.crc32;
		self.compress_size   = data_descriptor.compress_size;
		self.uncompress_size = data_descriptor.uncompress_size;
	}

	return self;
}

// TODO: Check if init_with_buffer is zip64 compatible.
fn ZipEntry*? ZipEntry.init_with_buffer(&self, Allocator allocator, String filename,
	char[] content, char[] compressed, ZipCompressMethod compress_method = COMPRESS_STORE)
{
	self.allocator       = allocator;
	self.version_min     = 0; 			// TODO: What's the minimum version?
	self.flag.language   = true; 			// We are only using utf-8 strings
	self.compress_method = compress_method;
	self.crc32 	     = crc32::hash(content);
	self.compress_size   = compressed.len;
	self.uncompress_size = content.len;
	self.filename        = filename.copy(allocator);

	self.version_used    = 0; // TODO: What's the version used?
	self.internal_attr   = 0;
	self.external_attr   = 0;

	return self;
}

fn void ZipEntry.free(&self)
{
	if (!self.allocator) return;
	self.filename.free(self.allocator);
	self.extra.free(self.allocator);
}

fn bool ZipEntry.is_zip64(&self) =>
	self.uncompress_size >= 0xFF_FF_FF_FF ||
	self.compress_size >= 0xFF_FF_FF_FF ||
	self.rel_offset >= 0xFF_FF_FF_FF;

fn void? ZipEntry.add_zip64_extra_field(&self)
{
	if (!self.is_zip64()) return; // Nothing to do here.

	Zip64ExtraField zip64_extra = {
		.header_id       = ZIP64_EXTRA_HEADER,
		.data_size       = 28, // We write out all values
		.uncompress_size = self.uncompress_size,
		.compress_size   = self.compress_size,
		.rel_offset      = self.rel_offset,
		.number          = 0
	};

	usz len = self.extra.len;
	char *p = (char*)allocator::realloc(self.allocator, self.extra.ptr, len + 28 + 4);
	self.extra = (String)p[:len + 28 + 4];

	zip64_extra.pack(self.extra[len .. ])!;
}

fn usz? ZipEntry.to_format(&self, Formatter *f) @dynamic
{
	return f.printf("%-40s %-12d %-12d %-12d\n", self.filename,
		self.compress_size, self.uncompress_size, self.compress_method);
}

<*
  Set DateTime to packed MS-DOS date and time.
*>
fn void ZipEntry.set_date_time(&self, DateTime t) @inline
{
	self.date.init(t);
	self.time.init(t);
}

<*
  Get DateTime from packed MS-DOS date and time.
*>
fn DateTime ZipEntry.get_date_time(&self) @inline
{
	return datetime::from_date(
		self.date.year + 1980,
		(Month)(self.date.month - 1),
		self.date.day,
		self.time.hours,
		self.time.minutes,
		self.time.halfsec * 2);
}

<*
 Bit 3 of general-purpose flag
*>
fn bool ZipEntry.is_streaming(&zf) => zf.flag.streaming;

<*
 Returns a LimitReader for the compressed (!) data of the ZipEntry.
 Do not close the LimitReader.
 @param [in] file : "Zip archive file stream"
*>
fn LimitReader? ZipEntry.open_compressed(&self, InStream file)
{
	file.seek(self.file_offset, Seek.SET)!;
	return { file, self.compress_size };
}

struct ExtractResult
{
	usz bytes;
	bool checksum_ok;
}

<*
 Extract, decompress and write the file content to an output stream.

 The CRC32 checksum of the decompressed data is calculated and compared to the
 stored checksum.

 @param file   : "Zip archive file."
 @param output : "Destination for decompressed data."
 @return "An ExtractResult with the number of decompressed bytes and checksum check."
*>
fn ExtractResult? ZipEntry.extract_to(&self, OutStream output, InStream file, bool verify_checksum = true) => @pool()
{
	char[] dst;

	switch (self.compress_method)
	{
	case COMPRESS_STORE:
		assert(self.compress_size == self.uncompress_size,
			"COMPRESS_METHOD_STORE: uncompressed and compressed sizes differ");
		dst = mem::temp_array(char, self.uncompress_size);
		io::read_all(&&self.open_compressed(file), dst)!;

	case COMPRESS_DEFLATE:
		char[] src = mem::temp_array(char, self.compress_size);
		io::read_all(&&self.open_compressed(file), src)!;
		dst = flate::tuncompress(src)!;

	default:
		return UNSUPPORTED_COMPRESSION~;
	}

	return {
		.bytes = io::write_all(output, dst)!,
		.checksum_ok = verify_checksum ? crc32::hash(dst) == self.crc32 : true,
	};
}

<*
 Unused
*>
struct ZipDigitalSignature
{
	uint   signature;
	ushort data_size;
	char[] data;
}

<*
 ZIP64 End of Central Directory Record

  Note that 'record_size' is the size in bytes of the "remaining" record (minus
  leading 12 bytes), i.e.

	 Size = SizeOfFixedFields + SizeOfVariableFields - 12

*>
struct Zip64EndRecord
{
	uint   signature;
	ulong  record_size;
	ushort version_made;
	ushort version_min;
	uint   nr_disk;
	uint   disk_start;
	ulong  nr_records;
	ulong  tot_nr_records;
	ulong  size_bytes;     // Size of central directory
	ulong  rel_offset;     // Offset to central directory (relative to start of archive)
}

fn void? Zip64EndRecord.unpack(&self, InStream file)
{
	char[56] buf;
	fill_buffer(&buf, file) ?? INVALID_END_RECORD~!;
	verify_signature(&buf, SIGNATURE_END_ZIP64)!;

	self.signature      = read_le_32(buf[ 0:4]);
	self.record_size    = read_le_64(buf[ 4:8]);
	self.version_made   = read_le_16(buf[12:2]);
	self.version_min    = read_le_16(buf[14:2]);
	self.nr_disk        = read_le_32(buf[16:4]);
	self.disk_start     = read_le_32(buf[20:4]);
	self.nr_records     = read_le_64(buf[24:8]);
	self.tot_nr_records = read_le_64(buf[32:8]);
	self.size_bytes     = read_le_64(buf[40:8]);
	self.rel_offset     = read_le_64(buf[48:8]);
}

<*
 ZIP64 End of Central Directory Locator
*>
struct Zip64EndLocator
{
	uint  signature;
	uint  disk_start;
	ulong rel_offset; // offset to Zip64EndRecord (relative to start of file)
	uint  tot_disks;
}

fn void? Zip64EndLocator.unpack(&self, InStream file)
{
	char[20] buf;
	fill_buffer(&buf, file) ?? INVALID_END_RECORD~!;
	verify_signature(&buf, SIGNATURE_LOCATOR_ZIP64)!;

	self.signature  = read_le_32(buf[ 0:4]);
	self.disk_start = read_le_32(buf[ 4:4]);
	self.rel_offset = read_le_64(buf[ 8:8]);
	self.tot_disks  = read_le_32(buf[16:4]);
}

<*
 End of central directory record
*>
struct ZipEndRecord (Printable)
{
	Allocator allocator;
	uint	  signature;
	ushort 	  number_of_disk;
	ushort    disk_start;
	ushort    nr_records;
	ushort    tot_nr_records;
	uint      size_bytes; 		// size of central directory
	uint      rel_offset; 		// relative to start of archive
	ushort    comment_len;
	String    comment; 		// comment.len == comment_len
}

fn void ZipEndRecord.free(&self)
{
	if (!self.allocator) return;
	self.comment.free(self.allocator);
	*self = {};
}

fn usz? ZipEndRecord.to_format(&self, Formatter *f) @dynamic
{
	usz n;
	n += f.printf("Signature: %x\n", self.signature)!;
	n += f.printf("Records  : %d\n", self.nr_records)!;
	n += f.printf("Total    : %d\n", self.tot_nr_records)!;
	n += f.printf("Size     : %d\n", self.size_bytes)!;
	n += f.printf("Offset   : %d\n", self.rel_offset)!;
	n += f.printf("Comment  : %s\n", self.comment)!;
	return n;
}

<*
*>
fn void? ZipEndRecord.unpack(&self, Allocator allocator, InStream file) => @pool()
{
	char[22] buf;
	fill_buffer(&buf, file) ?? INVALID_END_RECORD~!;
	verify_signature(&buf, SIGNATURE_END)!;

	self.allocator      = allocator;
	self.signature      = read_le_32(buf[ 0:4]);
	self.number_of_disk = read_le_16(buf[ 4:2]);
	self.disk_start     = read_le_16(buf[ 6:2]);
	self.nr_records     = read_le_16(buf[ 8:2]);
	self.tot_nr_records = read_le_16(buf[10:2]);
	self.size_bytes     = read_le_32(buf[12:4]);
	self.rel_offset     = read_le_32(buf[16:4]);
	self.comment_len    = read_le_16(buf[20:2]);
	self.comment        = read_string(allocator, file, self.comment_len)!;
}

<*
 General-purpose bit flag with only the relevant flags.
*>
bitstruct ZipFlag : ushort
{
	bool encrypted  :  0;	// indicates if file is encrypted
	bool streaming  :  3;	// crc32, sizes are unset; use Data Descriptor
	bool patched    :  5;	// indicates if file is encrypted
	bool language   : 11;	// language encoding flag
	bool enc_center : 13;	// encrypted central directory
}

<*
 Central directory file header

  central file header signature   4 bytes  (0x02014b50)
  version made by                 2 bytes
  version needed to extract       2 bytes
  general purpose bit flag        2 bytes
  compression method              2 bytes
  last mod file time              2 bytes
  last mod file date              2 bytes
  crc-32                          4 bytes
  compressed size                 4 bytes
  uncompressed size               4 bytes
  file name length                2 bytes
  extra field length              2 bytes
  file comment length             2 bytes
  disk number start               2 bytes
  internal file attributes        2 bytes
  external file attributes        4 bytes
  relative offset of local header 4 bytes

  file name (variable size)
  extra field (variable size)
  file comment (variable size)

*>
struct ZipCentralFileHeader
{
	Allocator allocator;
	uint      signature;
	ushort    version_used;
	ushort    version_min;
	ZipFlag   flag;
	ushort    compress_method;
	ushort    last_mod_time;
	ushort    last_mod_date;
	uint      crc32;		// of uncompressed data
	uint      compress_size;
	uint      uncompress_size;
	ushort    filename_len; 	// n
	ushort    extra_len; 		// m
	ushort    comment_len; 		// k
	ushort    disk_nr; 		// disk on which file starts
	ushort    internal_attr;
	uint      external_attr;
	uint      rel_offset; 		// relative offset of local file header
	String    filename; 		// filename.len == n
	String    extra; 		// extra.len == m
	String    comment; 		// comment.len == k
}

fn void ZipCentralFileHeader.free(&self)
{
	if (!self.allocator) return;
	self.filename.free(self.allocator);
	self.extra.free(self.allocator);
	self.comment.free(self.allocator);
	*self = {};
}

fn void? ZipCentralFileHeader.unpack(&self, Allocator allocator, InStream file)
{
	char[46] buf;
	fill_buffer(&buf, file) ?? INVALID_CENTRAL_FILE_HEADER~!;
	verify_signature(&buf, SIGNATURE_CENTRAL)!;

	self.allocator       = allocator;
	self.signature       = read_le_32(buf[ 0:4]);
	self.version_used    = read_le_16(buf[ 4:2]);
	self.version_min     = read_le_16(buf[ 6:2]);
	self.flag            = (ZipFlag)read_le_16(buf[ 8:2]);
	self.compress_method = read_le_16(buf[10:2]);
	self.last_mod_time   = read_le_16(buf[12:2]);
	self.last_mod_date   = read_le_16(buf[14:2]);
	self.crc32           = read_le_32(buf[16:4]);
	self.compress_size   = read_le_32(buf[20:4]);
	self.uncompress_size = read_le_32(buf[24:4]);
	self.filename_len    = read_le_16(buf[28:2]);
	self.extra_len       = read_le_16(buf[30:2]);
	self.comment_len     = read_le_16(buf[32:2]);
	self.disk_nr         = read_le_16(buf[34:2]);
	self.internal_attr   = read_le_16(buf[36:2]);
	self.external_attr   = read_le_32(buf[38:4]);
	self.rel_offset      = read_le_32(buf[42:4]);
	self.filename        = read_string(allocator, file, self.filename_len)!;
	self.extra           = read_string(allocator, file, self.extra_len)!;
	self.comment         = read_string(allocator, file, self.comment_len)!;
}

<*
 Local file header

  local file header signature     4 bytes  (0x04034b50)
  version needed to extract       2 bytes
  general purpose bit flag        2 bytes
  compression method              2 bytes
  last mod file time              2 bytes
  last mod file date              2 bytes
  crc-32                          4 bytes
  compressed size                 4 bytes
  uncompressed size               4 bytes
  file name length                2 bytes
  extra field length              2 bytes

  file name (variable size)
  extra field (variable size)

*>
struct ZipLocalFileHeader
{
	Allocator allocator;
	uint      signature;
	ushort    version_min;
	ZipFlag   flag;
	ushort    compress_method;
	ushort    last_mod_time;
	ushort    last_mod_date;
	uint      crc32; 		// of uncompressed data
	uint      compress_size;
	uint      uncompress_size;
	ushort    filename_len; 	// n
	ushort    extra_len; 		// m
	String    filename; 		// filename.len == n
	String    extra; 		// extra.len == m
}

fn void ZipLocalFileHeader.free(&self)
{
	if (!self.allocator) return;
	self.filename.free(self.allocator);
	self.extra.free(self.allocator);
	*self = {};
}

fn void? ZipLocalFileHeader.unpack(&self, Allocator allocator, InStream file)
{
	char[30] buf;
	fill_buffer(&buf, file) ?? INVALID_LOCAL_FILE_HEADER~!;
	verify_signature(&buf, SIGNATURE_LOCAL)!;

	self.allocator       = allocator;
	self.signature       = read_le_32(buf[ 0:4]);
	self.version_min     = read_le_16(buf[ 4:2]);
	self.flag            = (ZipFlag)read_le_16(buf[ 6:2]);
	self.compress_method = read_le_16(buf[ 8:2]);
	self.last_mod_time   = read_le_16(buf[10:2]);
	self.last_mod_date   = read_le_16(buf[12:2]);
	self.crc32           = read_le_32(buf[14:4]);
	self.compress_size   = read_le_32(buf[18:4]);
	self.uncompress_size = read_le_32(buf[22:4]);
	self.filename_len    = read_le_16(buf[26:2]);
	self.extra_len       = read_le_16(buf[28:2]);
	self.filename        = read_string(allocator, file, self.filename_len)!;
	self.extra           = read_string(allocator, file, self.extra_len)!;
}

<*
 Data descriptor

  crc-32                          4 bytes
  compressed size                 4 bytes (8 bytes for ZIP64)
  uncompressed size               4 bytes (8 bytes for ZIP64)

 This descriptor MUST exist if bit 3 of the general purpose bit flag is set. It
 is byte aligned and immediately follows the last byte of compressed data. This
 descriptor SHOULD be used only when it was not possible to seek in the output
 .ZIP file, e.g., when the output .ZIP file was standard output or a
 non-seekable device. For ZIP64(tm) format archives, the compressed and
 uncompressed sizes are 8 bytes each.

*>
struct ZipDataDescriptor
{
	uint  crc32;
	ulong compress_size; 	// make it ZIP64 ready with ulong
	ulong uncompress_size;  // make it ZIP64 ready with ulong
}

fn void? ZipDataDescriptor.unpack(&self, InStream file, bool zip64 = false)
{
	char[20] buf;
	usz len = zip64 ? 20 : 12;
	fill_buffer(buf[:len], file) ?? INVALID_DATA_DESCRIPTOR~!;

	self.crc32 = read_le_32(buf[0:4]);

	if (!zip64)
	{
		self.compress_size   = read_le_32(buf[4:4]);
		self.uncompress_size = read_le_32(buf[8:4]);
	}
	else
	{
		self.compress_size   = read_le_64(buf[ 4:8]);
		self.uncompress_size = read_le_64(buf[12:8]);
	}
}

fn void? fill_buffer(char[] buf, InStream file) @inline @private
{
	usz n = file.read(buf[..])!;
	if (n != buf.len) return CORRUPT_FILE~;
}

<*
 @require buf.len >= 4
*>
fn void? verify_signature(char[] buf, char[4] signature) @inline @private
{
	if (buf[:4] != signature[:4]) return SIGNATURE_MISMATCH~;
}

<*
 Pack two bytes into a ushort (little-endian).
 @require p.len >= 2
*>
fn ushort read_le_16(char[] p) @inline => io::read_le_ushort(&&io::wrap_bytes(p))!!;
<*
 Pack four bytes into an uint (little-endian).
 @require p.len >= 4
*>
fn uint read_le_32(char[] p) @inline => io::read_le_uint(&&io::wrap_bytes(p))!!;
<*
 Pack eight bytes into an ulong (little-endian).
 @require p.len >= 8
*>
fn ulong read_le_64(char[] p) @inline => io::read_le_ulong(&&io::wrap_bytes(p))!!;

<*
 Read n bytes from f and return a String.
*>
fn String? read_string(Allocator allocator, InStream f, usz n) @private
{
	if (n == 0) return "";
	char[] buf = allocator::alloc_array(allocator, char, n);
	usz read = 0;
	while (read < n)
	{
		read += f.read(buf[read : n - read])!;
	}
	return (String)buf[:n];
}

<*
 Scan from the end of the file for signature.
*>
fn usz? find_signature_r(InStream in, char[4] sig)
{
	usz i, n, size, offset;
	char[256] buf;

	size = in.seek(offset, Seek.END)!;

	offset = 0;
	while (offset < size)
	{
		offset += 128;
		if (offset > size) offset = size;
		in.seek(-offset, Seek.END)!;
		n = in.read(&buf)!;

		// Scan for end record magic number
		if (try loc = ((String)buf[:n]).index_of((String)sig[..]))
		{
			return size - offset + loc;
		}
	}

	return NOT_FOUND~;
}

<*
 Scan from the current file cursor for a signature.
*>
fn usz? find_next_signature(InStream in, char[4] sig)
{
	usz n;
	char[256] buf;

	while (try read = in.read(&buf) && read > 0)
	{
		n += read;

		// Scan for Signature
		if (try loc = ((String)buf[:read]).index_of((String)sig[..]))
		{
			return in.seek(0,Seek.CURSOR)! - read + loc;
		}
	}

	return NOT_FOUND~;
}
