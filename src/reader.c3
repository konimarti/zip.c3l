module archive::zip;

import std::io;
import std::time;
import std::hash::crc32;
import std::collections::list;

import tinf::inflate;

<*
 ZipReader stores the metadata for a Zip archive. Metadata includes the
 relevant offset to seek the local file header (stored in the ZipEntries),
 central directory headers, and end of record.
*>
struct ZipReader (Printable)
{
	// Indicate ZIP64 file format if true
	bool zip64;

	// Wrapped Zip archive
	InStream file;

	// Offsets
	ulong offset_end_record;
	ulong offset_central_directory;

	// File information in Zip archive
	ZipEntry[] entries;

	Allocator allocator;
}

fn void? ZipReader.tparse(&z, InStream file) => z.parse(tmem, file);
fn void? ZipReader.parse(&z, Allocator allocator, InStream file) => @pool()
{
	usz nrecords, offset;

	ZipLocalFileHeader lh;
	ZipCentralFileHeader ch;
	ZipDataDescriptor dd;
	ZipEndRecord record;

	z.allocator = allocator;
	defer catch z.free();

	if (try loc = find_signature_r(file, SIGNATURE_END))
	{
		z.offset_end_record = loc;
	}
	else
	{
		// TODO: Check for Central Directory header as another fallback option?

		// Fallback: End Record not found, scan for Local File Header
		List {ZipEntry} list;
		list.init(allocator);

		file.seek(0, Seek.SET)!;
		while (try loc = find_next_signature(file, SIGNATURE_LOCAL))
		{

			file.seek(loc, Seek.SET)!;
			lh.unpack(file, tmem)!;

			// Hack together an (incomplete) Central Directory File header
			ch.filename        = lh.filename.copy(allocator);
			ch.filename_len    = lh.filename_len;
			ch.extra           = lh.extra.copy(allocator);
			ch.extra_len       = lh.extra_len;
			ch.compress_size   = lh.compress_size;
			ch.uncompress_size = lh.uncompress_size;
			ch.compress_method = lh.compress_method;
			ch.crc32           = lh.crc32;
			ch.rel_offset      = (uint)loc;

			list.push(*(ZipEntry){}.init(allocator, ch, lh)!);
		}

		z.entries = list.array_view();

		return;
	}

	file.seek(z.offset_end_record, Seek.SET)!;
	record.unpack(file, tmem)!;

	z.offset_central_directory = record.rel_offset;

	offset   = record.rel_offset;
	nrecords = record.tot_nr_records;

	z.zip64 = offset == 0xFF_FF_FF_FF || nrecords == 0xFF_FF;

	if (z.zip64)
	{
		Zip64EndLocator locator;
		Zip64EndRecord record_z64;

		// Find the Zip64 Locator
		usz loc = find_signature_r(file, SIGNATURE_LOCATOR_ZIP64)!;
		file.seek(loc, Seek.SET)!;
		locator.unpack(file)!;

		// Parse Zip64 End Record
		file.seek(locator.rel_offset, Seek.SET)!;
		record_z64.unpack(file)!;

		z.offset_central_directory = record_z64.rel_offset;
		offset   = record_z64.rel_offset;
		nrecords = record_z64.tot_nr_records;
	}

	z.entries = allocator::new_array(allocator, ZipEntry, nrecords);

	// Read file headers
	foreach (&zip_file : z.entries)
	{
		file.seek(offset, Seek.SET)!;
		ch.unpack(file, tmem)!;
		offset = file.seek(0, Seek.CURSOR)!;

		file.seek(ch.rel_offset, Seek.SET)!;

		lh.unpack(file, tmem)!;
		if (ch.flag.streaming)
		{
			// TODO: Write a unit test for a streamed Zip archive.

			// When we are streaming, we dont have the
			// compress_size available. What we need to do is scan
			// for the next local header file and use the central
			// directory offset as a guide when we reach EOF. The
			// data descriptor is then "read" backwards from the
			// next locator or the central directory offset.
			if (try loc = find_next_signature(file, SIGNATURE_LOCAL))
			{
				file.seek(z.zip64 ? -20 : -12, Seek.CURSOR)!;
				dd.unpack(file, z.zip64)!;
			}
			else
			{
				// `find_next_signature` threw pobably an EOF
				// error; so we assume we are looking at the
				// last file that ends with central directory.
				file.seek(z.offset_central_directory + (z.zip64 ? -20 : -12), Seek.SET)!;
			}
			dd.unpack(file, z.zip64)!;
		}

		zip_file.init(allocator, ch, lh, dd)!;
	}
}

fn void ZipReader.free(&z)
{
	if (!z.allocator) return;
	foreach (&zip_file : z.entries) zip_file.free();
	allocator::free(z.allocator, z.entries);
	*z = {};
}
fn void ZipReader.close(&z) => z.free();

fn usz? ZipReader.to_format(&z, Formatter *f) @dynamic
{
	// TODO: Not implemented yet.
	return 0;
}

fn usz ZipReader.len(&z) @operator(len) => z.entries.len;

fn ZipEntry ZipReader.get(&z, usz index) @operator([]) => z.entries[index];

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

fn usz? ZipDate.to_format(&self, Formatter *f) @dynamic
{
	return f.printf("%04d-%02d-%02d", self.year + 1980, self.month, self.day);
}

<*
 ZipEntry contains the metadata for a file entry in the zip archive.
*>
struct ZipEntry
{
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

	Allocator allocator;
}

fn ZipEntry*? ZipEntry.init(&entry, Allocator allocator, ZipCentralFileHeader cfh, ZipLocalFileHeader lfh, ZipDataDescriptor desc = {})
{
	// Data from Local File Header
	entry.version_min        = lfh.version_min;
	entry.flag               = lfh.flag;
	entry.compress_method    = lfh.compress_method;
	entry.time.last_mod_time = lfh.last_mod_time;
	entry.date.last_mod_date = lfh.last_mod_date;
	entry.crc32              = lfh.crc32;
	entry.compress_size      = lfh.compress_size;
	entry.uncompress_size    = lfh.uncompress_size;
	entry.extra              = lfh.extra.copy(allocator);

	// Obtain filename
	if (entry.flag.language)
	{
		entry.filename = lfh.filename.copy(allocator);;
	}
	else if (try block = find_extra_header(entry.extra, UNICODE_PATH_HEADER))
	{
		UnicodePathExtraField ex;
		ex.unpack(block)!;
		entry.filename = ex.filename.copy(allocator);
	}
	else
	{
		entry.filename = lfh.filename.copy(allocator);
	}

	// Data from Central Directory Header
	entry.version_used  = cfh.version_used;
	entry.internal_attr = cfh.internal_attr;
	entry.external_attr = cfh.external_attr;
	entry.rel_offset    = cfh.rel_offset;
	entry.file_offset   = (ulong)cfh.rel_offset + 30 + lfh.filename_len + lfh.extra_len;

	// Check for ZIP64 and replace the corrsponding field
	if (entry.is_zip64())
	{
		if (try block = find_extra_header(entry.extra, ZIP64_EXTRA_HEADER))
		{
			Zip64ExtraField ex;
			ex.unpack(block)!;
			if (entry.compress_size   == 0xFF_FF_FF_FF) entry.compress_size   = ex.compress_size;
			if (entry.uncompress_size == 0xFF_FF_FF_FF) entry.uncompress_size = ex.uncompress_size;
			if (entry.rel_offset      == 0xFF_FF_FF_FF) entry.rel_offset      = ex.rel_offset;
		}
	}

	// Data from Data Descriptor (if needed)
	if (entry.flag.streaming)
	{
		entry.crc32           = desc.crc32;
		entry.compress_size   = desc.compress_size;
		entry.uncompress_size = desc.uncompress_size;
	}

	entry.allocator = allocator;

	return entry;
}

fn bool ZipEntry.is_zip64(&self) =>
	self.uncompress_size >= 0xFF_FF_FF_FF ||
	self.compress_size >= 0xFF_FF_FF_FF ||
	self.rel_offset >= 0xFF_FF_FF_FF;

fn void? ZipEntry.format_zip64(&self)
{
	if (!self.is_zip64()) return; // Nothing to do here

	Zip64ExtraField ex = {
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

	ex.pack(self.extra[len .. ])!;
}

fn void ZipEntry.free(&self)
{
	if (!self.allocator) return;
	self.filename.free(self.allocator);
	self.extra.free(self.allocator);
}

fn usz? ZipEntry.to_format(&zf, Formatter *f) @dynamic
{
	return f.printf("%-40s %-12d %-12d %-12d\n",
			zf.filename, zf.compress_size, zf.uncompress_size, zf.compress_method);
}

<*
  Set DateTime to packed MS-DOS date and time.
*>
fn void ZipEntry.set_date_time(&entry, DateTime t) @inline
{
	entry.date.year    = (char)(t.year - 1980);
	entry.date.month   = t.month.ordinal + 1;
	entry.date.day     = t.day;
	entry.time.hours   = t.hour;
	entry.time.minutes = t.min;
	entry.time.halfsec = t.sec / 2;
}

<*
  Get DateTime from packed MS-DOS date and time.
*>
fn DateTime ZipEntry.get_date_time(&entry) @inline
{
	return datetime::from_date(
		entry.date.year + 1980,
		(Month)(entry.date.month - 1),
		entry.date.day,
		entry.time.hours,
		entry.time.minutes,
		entry.time.halfsec * 2);
}

<*
 Bit 3 of general-purpose flag
*>
fn bool ZipEntry.streaming(&zf) => zf.flag.streaming;

<*
 Returns a LimitReader for the compressed (!) data of the ZipEntry.
 Do not close the LimitReader.
 @param [in] archive : "Zip archive file stream"
*>
fn LimitReader? ZipEntry.compressed_data(&zf, InStream archive)
{
	archive.seek(zf.file_offset, Seek.SET)!;
	return { archive, zf.compress_size };
}

<*
 Extract, decompress and write the file content to an output stream.

 The CRC32 checksum of the decompressed data is calculated and compared to the
 stored checksum.

 @param archive : "Zip Archive stream"
 @param output  : "Write decompressed data to writer"
 @return "Number of (decompressed) bytes written to output"
*>
fn usz? ZipEntry.extract_to(&zf, InStream archive, OutStream output, bool *checksum = null) => @pool()
{
	char[] src, dst;

	dst = mem::temp_array(char, zf.uncompress_size);

	switch (zf.compress_method)
	{
	case COMPRESS_STORE:
		assert(zf.compress_size == zf.uncompress_size,
			"COMPRESS_METHOD_STORE: uncompressed and compressed sizes differ");

		// Read all data from limit reader
		io::read_all(&&zf.compressed_data(archive), dst)!;

	case COMPRESS_DEFLATE:
		assert(zf.compress_size != zf.uncompress_size,
			"COMPRESS_METHOD_DEFLATE: compressed is larger than uncompressed size?");

		// Read all data from limit reader
		src = mem::temp_array(char, zf.compress_size);
		io::read_all(&&zf.compressed_data(archive), src)!;

		// Uncompress data
		inflate::uncompress(dst, src)!;

	case COMPRESS_BZIP2:
	default:
		return UNSUPPORTED_COMPRESSION_METHOD?;
	}

	// Verify checksum
	if (checksum) *checksum = crc32::hash(dst) == zf.crc32;

	// Write data
	return io::write_all(output, dst);
}

<*
 Unused
*>
struct ZipDigitalSignature
{
	uint 	signature;
	ushort  data_size;
	char[]  data;
}

<*
 ZIP64 End of Central Directory Record

  Note that 'record_size' is the size in bytes of the "remaining" record (minus
  leading 12 bytes), i.e.

	 Size = SizeOfFixedFields + SizeOfVariableFields - 12

*>
struct Zip64EndRecord
{
	uint	  signature;
	ulong 	  record_size;
	ushort    version_made;
	ushort    version_min;
	uint      nr_disk;
	uint      disk_start;
	ulong     nr_records;
	ulong     tot_nr_records;
	ulong     size_bytes; 	  // size of central directory
	ulong     rel_offset; 	  // offset to central directory (relative to start of archive)
	// char[]    data;           // zip64 extensible data sector (header: 2 bytes, len: 4 bytes, data[len] ..)
	// Allocator allocator;
}

fn void? Zip64EndRecord.unpack(&r, InStream in)
{
	char[56] buf;

	if (in.read(buf[..])! != 56) return INVALID_END_RECORD?;

	if (buf[:4] != SIGNATURE_END_ZIP64[:4]) return SIGNATURE_MISMATCH?;

	r.signature      = read_le_32(buf[ 0:4]);
	r.record_size    = read_le_64(buf[ 4:8]);
	r.version_made   = read_le_16(buf[12:2]);
	r.version_min    = read_le_16(buf[14:2]);
	r.nr_disk        = read_le_32(buf[16:4]);
	r.disk_start     = read_le_32(buf[20:4]);
	r.nr_records     = read_le_64(buf[24:8]);
	r.tot_nr_records = read_le_64(buf[32:8]);
	r.size_bytes     = read_le_64(buf[40:8]);
	r.rel_offset     = read_le_64(buf[48:8]);
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

fn void? Zip64EndLocator.unpack(&r, InStream in)
{
	char[20] buf;

	if (in.read(buf[..])! != 20) return INVALID_END_RECORD?;

	if (buf[:4] != SIGNATURE_LOCATOR_ZIP64[:4]) return SIGNATURE_MISMATCH?;

	r.signature      = read_le_32(buf[ 0:4]);
	r.disk_start     = read_le_32(buf[ 4:4]);
	r.rel_offset     = read_le_64(buf[ 8:8]);
	r.tot_disks      = read_le_32(buf[16:4]);
}

<*
 End of central directory record
*>
struct ZipEndRecord (Printable)
{
	uint	  signature;
	ushort 	  number_of_disk;
	ushort    disk_start;
	ushort    nr_records;
	ushort    tot_nr_records;
	uint      size_bytes; 		// size of central directory
	uint      rel_offset; 		// relative to start of archive
	ushort    comment_len;
	String    comment; 		// comment.len == comment_len
	Allocator allocator;
}

fn void ZipEndRecord.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.comment);
	*self = {};
}

fn usz? ZipEndRecord.to_format(&self, Formatter *f) @dynamic
{
	usz n;
	n += f.printf("magic num : %x\n", self.signature)!;
	n += f.printf("records   : %d\n", self.nr_records)!;
	n += f.printf("total     : %d\n", self.tot_nr_records)!;
	n += f.printf("size      : %d\n", self.size_bytes)!;
	n += f.printf("rel_offset: %d\n", self.rel_offset)!;
	n += f.printf("comment   : %s\n", self.comment)!;
	return n;
}

<*
*>
fn void? ZipEndRecord.unpack(&r, InStream in, Allocator allocator = mem) => @pool()
{
	char[22] buf;

	if (in.read(buf[..])! != 22) return INVALID_END_RECORD?;

	if (buf[:4] != SIGNATURE_END[:4]) return SIGNATURE_MISMATCH?;

	r.signature   = read_le_32(buf[ 0:4]);
	r.number_of_disk = read_le_16(buf[ 4:2]);
	r.disk_start     = read_le_16(buf[ 6:2]);
	r.nr_records     = read_le_16(buf[ 8:2]);
	r.tot_nr_records = read_le_16(buf[10:2]);
	r.size_bytes     = read_le_32(buf[12:4]);
	r.rel_offset     = read_le_32(buf[16:4]);
	r.comment_len    = read_le_16(buf[20:2]);
	r.comment        = read_n(in, r.comment_len, allocator)!;
	r.allocator      = allocator;
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
	Allocator allocator;
}

fn void ZipCentralFileHeader.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.filename);
	allocator::free(self.allocator, self.extra);
	allocator::free(self.allocator, self.comment);
	*self = {};
}

fn void? ZipCentralFileHeader.unpack(&c, InStream in, Allocator allocator = mem) => @pool()
{
	char[46] buf;

	if (in.read(buf[..])! != 46) return INVALID_CENTRAL_FILE_HEADER?;

	if (buf[:4] != SIGNATURE_CENTRAL[:4]) return SIGNATURE_MISMATCH?;

	c.signature    = read_le_32(buf[ 0:4]);
	c.version_used    = read_le_16(buf[ 4:2]);
	c.version_min     = read_le_16(buf[ 6:2]);
	c.flag            = (ZipFlag)read_le_16(buf[ 8:2]);
	c.compress_method = read_le_16(buf[10:2]);
	c.last_mod_time   = read_le_16(buf[12:2]);
	c.last_mod_date   = read_le_16(buf[14:2]);
	c.crc32           = read_le_32(buf[16:4]);
	c.compress_size   = read_le_32(buf[20:4]);
	c.uncompress_size = read_le_32(buf[24:4]);
	c.filename_len    = read_le_16(buf[28:2]);
	c.extra_len       = read_le_16(buf[30:2]);
	c.comment_len     = read_le_16(buf[32:2]);
	c.disk_nr         = read_le_16(buf[34:2]);
	c.internal_attr   = read_le_16(buf[36:2]);
	c.external_attr   = read_le_32(buf[38:4]);
	c.rel_offset      = read_le_32(buf[42:4]);
	c.filename        = read_n(in, c.filename_len, allocator)!;
	c.extra           = read_n(in, c.extra_len, allocator)!;
	c.comment         = read_n(in, c.comment_len, allocator)!;
	c.allocator       = allocator;
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
	Allocator allocator;
}

fn void ZipLocalFileHeader.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.filename);
	allocator::free(self.allocator, self.extra);
	*self = {};
}

fn void? ZipLocalFileHeader.unpack(&f, InStream in, Allocator allocator = mem) => @pool()
{
	char[30] buf;

	if (in.read(buf[..])! != 30) return INVALID_LOCAL_FILE_HEADER?;

	if (buf[:4] != SIGNATURE_LOCAL[:4]) return SIGNATURE_MISMATCH?;

	f.signature       = read_le_32(buf[ 0:4]);
	f.version_min     = read_le_16(buf[ 4:2]);
	f.flag            = (ZipFlag)read_le_16(buf[ 6:2]);
	f.compress_method = read_le_16(buf[ 8:2]);
	f.last_mod_time   = read_le_16(buf[10:2]);
	f.last_mod_date   = read_le_16(buf[12:2]);
	f.crc32           = read_le_32(buf[14:4]);
	f.compress_size   = read_le_32(buf[18:4]);
	f.uncompress_size = read_le_32(buf[22:4]);
	f.filename_len    = read_le_16(buf[26:2]);
	f.extra_len       = read_le_16(buf[28:2]);
	f.filename        = read_n(in, f.filename_len, allocator)!;
	f.extra           = read_n(in, f.extra_len, allocator)!;
	f.allocator       = allocator;
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
	// signature is optional
	uint crc32;
	ulong compress_size; 	// make it ZIP64 ready with ulong
	ulong uncompress_size;  // make it ZIP64 ready with ulong
}

fn void? ZipDataDescriptor.unpack(&d, InStream in, bool zip64 = false)
{
	char[20] buf;
	usz n = zip64 ? 20 : 12;
	if (in.read(buf[:n])! != n) return INVALID_DATA_DESCRIPTOR?;

	d.crc32 = read_le_32(buf[0:4]);

	if (!zip64)
	{
		d.compress_size   = read_le_32(buf[4:4]);
		d.uncompress_size = read_le_32(buf[8:4]);
	}
	else
	{
		d.compress_size   = read_le_64(buf[ 4:8]);
		d.uncompress_size = read_le_64(buf[12:8]);
	}
}
