<*
 Archive::zip provides the functionality to handle the ZIP format.

 ZIP specification: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
 AES encryption:    https://www.winzip.com/en/support/aes-encryption/

*>
module archive::zip;

import std::io;
import std::hash::crc32;
import std::collections::list;

import tinf::inflate;

// Compression methods
alias CompressMethod = uint;
const CompressMethod COMPRESS_STORE   = 0;
const CompressMethod COMPRESS_DEFLATE = 8;
const CompressMethod COMPRESS_BZIP2   = 12; // TODO: unsupported
const CompressMethod COMPRESS_ZSTD    = 93; // TODO: unsupported
const CompressMethod COMPRESS_MP3     = 94; // TODO: unsupported
const CompressMethod COMPRESS_XZ      = 95; // TODO: unsupported
const CompressMethod COMPRESS_JPEG    = 96; // TODO: unsupported
const CompressMethod COMPRESS_AEX     = 99; // TODO: unsupported

// Signatures
const char[*] SIGNATURE_CENTRAL       = {0x50, 0x4b, 0x01, 0x02};
const char[*] SIGNATURE_LOCAL         = {0x50, 0x4b, 0x03, 0x04};
const char[*] SIGNATURE_END           = {0x50, 0x4b, 0x05, 0x06};
const char[*] SIGNATURE_END_ZIP64     = {0x50, 0x4b, 0x06, 0x06};
const char[*] SIGNATURE_LOCATOR_ZIP64 = {0x50, 0x4b, 0x06, 0x07};
const char[*] SIGNATURE_DATA          = {0x50, 0x4b, 0x07, 0x08}; // optional
const char[*] SIGNATURE_DIGITAL_SIG   = {0x50, 0x4b, 0x05, 0x05};

faultdef NOT_FOUND,
	INVALID_END_RECORD,
	INVALID_CENTRAL_FILE_HEADER,
	INVALID_LOCAL_FILE_HEADER,
	INVALID_DATA_DESCRIPTOR,
	INVALID_CRC32_HASH,
	SIGNATURE_MISMATCH,
	UNSUPPORTED_COMPRESSION_METHOD,
	UNSUPPORTED_ZIP64;

<*
 Read a zip archive and return its metadata
*>
fn ZipMeta? read(Allocator allocator, InStream file)
{
	ZipMeta z;
	z.parse(allocator, file)!;
	return z;
}
fn ZipMeta? tread(InStream file) => read(tmem, file);

<*
 ls lists the filenames in the ZIP archive.
*>
fn PathList? ls(Allocator allocator, InStream file) => @pool()
{
	ZipMeta z;
	z.tparse(file)!;

	PathList list;
	list.init(allocator);
	defer catch list.free();

	foreach (zip_file : z)
	{
		String path_str = path::normalize(zip_file.filename(), PathEnv.POSIX)!;
		Path path = path::new(allocator, path_str)!!;
		list.push(path);
	}
	return list;
}

<*
 Extracts the files to the folder

 @require path::is_dir(base_folder) : "Folder must be a directory"
*>
fn void? extract(InStream file, Path base_folder) => @pool()
{
	ZipMeta z;
	z.tparse(file)!;

	String filename, path_str;
	Path   folder, path;
	bool   is_directory;

	foreach (zip_file : z)
	{
		filename = zip_file.filename()!;
		is_directory = filename.ends_with("/");

		// Normalize path from UNIX sep to whatever is used
		path_str = path::normalize(zip_file.filename(), PathEnv.POSIX)!;
		path = base_folder.tappend(path_str)!;

		// Build directory structure
		if (is_directory)
		{
			path::mkdir(path, true)!;
			continue;
		}
		path::mkdir(path.dirname(), true)!;

		// Extract file
		File save = file::open(path.str_view(), "w")!;
		zip_file.copy_to(file, &save)!;
		save.close()!;
	}
}

<*
 Store the metadata for a zip archive. Metadata includes local, central file
 headers and data descriptor as well as the end record.
*>
struct ZipMeta (Printable)
{
	// Indicate Zip format (zip64 if true)
	bool zip64;

	// End records are mainly used for parsing the zip file
	union
	{
		struct z64
		{
			Zip64EndRecord  record;
			Zip64EndLocator locator;
		}
		ZipEndRecord record;
	}

	// Relevant file information is stored here
	ZipFile[]    files;

	Allocator    allocator;
}

alias ZipFileList = List { ZipFile };

fn void? ZipMeta.tparse(&z, InStream file) => z.parse(tmem, file);
fn void? ZipMeta.parse(&z, Allocator allocator, InStream file)
{
	usz nrecords, offset, end_record_loc;

	z.allocator = allocator;
	defer catch z.free();

	if (try loc = find_signature_r(file, SIGNATURE_END))
	{
		end_record_loc = loc;
	}
	else
	{
		// Fallback: End Record not found, scan for Local File Header
		ZipFileList list;
		list.init(allocator);

		file.seek(0, Seek.SET)!;
		while (try loc = find_next_signature(file, SIGNATURE_LOCAL))
		{
			ZipFile zip_file;

			file.seek(loc, Seek.SET)!;
			zip_file.local_header.parse(file, allocator)!;

			// Hack together an (incomplete) Central Directory File header
			zip_file.central_header.filename = zip_file.local_header.filename.copy(allocator);
			zip_file.central_header.filename_len = zip_file.local_header.filename_len;
			zip_file.central_header.extra = zip_file.local_header.extra.copy(allocator);
			zip_file.central_header.extra_len = zip_file.local_header.extra_len;
			zip_file.central_header.compress_size = zip_file.local_header.compress_size;
			zip_file.central_header.uncompress_size = zip_file.local_header.uncompress_size;
			zip_file.central_header.compress_method = zip_file.local_header.compress_method;
			zip_file.central_header.crc32 = zip_file.local_header.crc32;
			zip_file.central_header.rel_offset = (uint)loc;

			list.push(zip_file);
		}

		z.files = list.array_view();

		return;
	}

	file.seek(end_record_loc, Seek.SET)!;
	z.record.parse(file, allocator)!;

	offset = z.record.rel_offset;
	nrecords = z.record.tot_nr_records;

	if (offset == 0xFF_FF_FF_FF || nrecords == 0xFF_FF)
	{
		z.zip64 = true;

		// Find the Zip64 Locator
		end_record_loc = find_signature_r(file, SIGNATURE_LOCATOR_ZIP64)!;
		file.seek(end_record_loc, Seek.SET)!;
		z.z64.locator.parse(file)!;

		// Parse Zip64 End Record
		file.seek(z.z64.locator.rel_offset, Seek.SET)!;
		z.z64.record.parse(file)!;

		offset = z.z64.record.rel_offset;
		nrecords = z.z64.record.tot_nr_records;
	}

	z.files = allocator::new_array(allocator, ZipFile, nrecords);

	// Read central directory file headers
	file.seek(offset, Seek.SET)!;
	foreach (&zip_file : z.files)
	{
		zip_file.central_header.parse(file, allocator)!;
	}

	// Read local file headers
	foreach (&zip_file : z.files)
	{
		offset = zip_file.local_offset()!;
		file.seek(offset, Seek.SET)!;
		zip_file.local_header.parse(file, allocator)!;
		if (zip_file.streaming())
		{
			offset += zip_file.compressed_size()!;
			file.seek(offset, Seek.SET)!;
			zip_file.data_descriptor.parse(file, z.zip64)!;
		}
	}
}

fn void ZipMeta.free(&z)
{
	if (!z.allocator) return;

	z.record.free();

	foreach (&zip_file : z.files) zip_file.free();
	allocator::free(z.allocator, z.files);

	*z = {};
}

fn usz? ZipMeta.to_format(&z, Formatter *f) @dynamic
{
	// TODO: Not implemented yet.
	return 0;
}

fn usz ZipMeta.len(&z) @operator(len) => z.files.len;

fn ZipFile ZipMeta.get(&z, usz index) @operator([]) => z.files[index];


<*
 ZipFile contains the metadata for a file entry in the zip archive.
*>
struct ZipFile
{
	ZipCentralFileHeader central_header;
	ZipLocalFileHeader   local_header;
	ZipDataDescriptor    data_descriptor;
}

fn void ZipFile.free(&self)
{
	self.central_header.free();
	self.local_header.free();
}

fn usz? ZipFile.to_format(&zf, Formatter *f) @dynamic
{
	return f.printf("%-40s %-12d %-12d %-12d\n",
			zf.filename(), zf.compressed_size(), zf.uncompressed_size(), zf.compression_method());
}

<*
 Filename with forward slash ('/') as separator according to 4.4.16 of the spec.
*>
fn String? ZipFile.filename(&zf)
{
	// If language encoding flag is set, use filename directly
	if (zf.central_header.flag.language) return zf.central_header.filename;

	// If a Unicode Path Extra field is present, use this
	return @zip_extra_get("filename", zf.central_header, UnicodePathExtraField, UNICODE_PATH_HEADER);
}

// TODO: This contract fails, but should it?
//@require types::is_same($typeof($ExtraType.$eval(#field)), $typeof(central_header.$eval(#field))) : "Field type mismatch"
<*
*>
macro @zip_extra_get(#field, central_header, $ExtraType, ushort header_id)
{
	// Extract Zip64 from extra data
	if (try data = find_extra_header(central_header.$eval("extra"), header_id))
	{
		$ExtraType f;
		f.parse(data)!;
		return f.$eval(#field);
	}
	else
	{
		return central_header.$eval(#field);
	}
}

<*
 Extract a specific field from the char[] extra block of a Central Directory Header.

 @require $defined($ExtraType.$eval(#field)) : "Types is missing #field"
 @require $defined(central_header.$eval(#field)) : "Central Header Type is missing #field"
 @require $defined(central_header.$eval("extra")) : "Central Header Type is missing 'char[] extra' field"
*>
macro @zip_extra_ulong(#field, central_header, $ExtraType, ushort header_id)
{
	ulong size = (ulong)central_header.$eval(#field);

	$switch $sizeof(central_header.$eval(#field)):
	$case 4: if (size != 0xFF_FF_FF_FF) return size;
	$case 2: if (size != 0xFF_FF) return size;
	$default: $error("unsupported field size");
	$endswitch

	// Extract Zip64 from extra data
	return (ulong)@zip_extra_get(#field, central_header, $ExtraType, header_id);
}

macro @zip64_extra(#field, central_header) => @zip_extra_ulong(#field, central_header, Zip64ExtraField, ZIP64_EXTRA_HEADER);

<*
 Offset to local file header
*>
fn ulong? ZipFile.local_offset(&zf)
{
	return @zip64_extra("rel_offset", zf.central_header);
	// TODO: Remove below after Zip64 verification
	// uint offset = zf.central_header.rel_offset;
	// if (offset == 0xFF_FF_FF_FF)
	// {
	// 	// Zip64
	// 	if (try data = find_extra_header(zf.central_header.extra, ZIP64_EXTRA_HEADER))
	// 	{
	// 		Zip64ExtraField f;
	// 		f.parse(data)!;
	// 		return (ulong)f.rel_offset;
	// 	}
	// }
	// return (ulong)offset;
}

<*
 Compressed Size (as it is stored in Zip archive).
*>
fn ulong? ZipFile.compressed_size(&zf)
{
	return @zip64_extra("compress_size", zf.central_header);
	// TODO: Remove below after Zip64 verification
	// uint size = zf.central_header.compress_size;
	// if (size == 0xFF_FF_FF_FF)
	// {
		// Zip64
		// if (try data = find_extra_header(zf.central_header.extra, ZIP64_EXTRA_HEADER))
		// {
		// 	Zip64ExtraField f;
		// 	f.parse(data)!;
		// 	return (ulong)f.compress_size;
		// }
	// }
	// return (ulong)size;
}

<*
 Uncompressed Size (after extraction and uncompression).
*>
fn ulong? ZipFile.uncompressed_size(&zf)
{
	return @zip64_extra("uncompress_size", zf.central_header);
	// TODO: Remove below after Zip64 verification
	// uint size = zf.central_header.uncompress_size;
	// if (size == 0xFF_FF_FF_FF)
	// {
	// 	// Zip64
	// 	if (try data = find_extra_header(zf.central_header.extra, ZIP64_EXTRA_HEADER))
	// 	{
	// 		Zip64ExtraField f;
	// 		f.parse(data)!;
	// 		return (ulong)f.uncompress_size;
	// 	}
	// }
	// return (ulong)size;
}

<*
 Bit 3 of general-purpose flag
*>
fn bool ZipFile.streaming(&zf) => zf.central_header.flag.streaming;

<*
 CRC32 of uncompressed data.
*>
fn uint ZipFile.crc32(&zf) => zf.central_header.crc32;

<*
 CRC32 of uncompressed data.

 @require zf.central_header.compress_method == zf.local_header.compress_method : "Inconsistent compression method between Center and Local file headers"
*>
fn CompressMethod ZipFile.compression_method(&zf) => (usz)zf.central_header.compress_method;

<*
 Returns a LimitReader for the compressed (!) data of the ZipFile.
 Do not close the LimitReader.
 @param [in] file : "Zip archive file stream"
*>
fn LimitReader? ZipFile.reader(&zf, InStream file)
{
	ulong loc = zf.local_offset()! + 30 + zf.local_header.filename_len + zf.local_header.extra_len;
	file.seek(loc, Seek.SET)!;

	return { file, zf.compressed_size() };
}

<*
 Decompress data and write it to OutStream out.
*>
fn usz? ZipFile.copy_to(&zf, InStream file, OutStream writer) => @pool()
{
	char[] src, dst;

	dst = mem::temp_array(char, zf.uncompressed_size()!);

	switch (zf.compression_method())
	{
	case COMPRESS_STORE:
		assert(zf.compressed_size()! == zf.uncompressed_size()!,
			"COMPRESS_METHOD_STORE: uncompressed and compressed sizes differ");

		// Read all data from limit reader
		io::read_all(&&zf.reader(file), dst)!;

	case COMPRESS_DEFLATE:
		assert(zf.compressed_size()! != zf.uncompressed_size()!,
			"COMPRESS_METHOD_DEFLATE: uncompressed and compressed sizes match");

		// Read all data from limit reader
		src = mem::temp_array(char, zf.compressed_size()!);
		io::read_all(&&zf.reader(file), src)!;

		// Uncompress data
		inflate::uncompress(dst, src)!;

	case COMPRESS_BZIP2:
	default:
		return UNSUPPORTED_COMPRESSION_METHOD?;
	}

	// Verify crc32 hash
	if (crc32::hash(dst) != zf.crc32()) return INVALID_CRC32_HASH?;

	// Write data
	return io::write_all(writer, dst);
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

fn void? Zip64EndRecord.parse(&r, InStream in)
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

fn void? Zip64EndLocator.parse(&r, InStream in)
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
fn void? ZipEndRecord.parse(&r, InStream in, Allocator allocator = mem) => @pool()
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

fn void? ZipCentralFileHeader.parse(&c, InStream in, Allocator allocator = mem) => @pool()
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

fn void? ZipLocalFileHeader.parse(&f, InStream in, Allocator allocator = mem) => @pool()
{
	char[30] buf;

	if (in.read(buf[..])! != 30) return INVALID_LOCAL_FILE_HEADER?;

	if (buf[:4] != SIGNATURE_LOCAL[:4]) return SIGNATURE_MISMATCH?;

	f.signature    = read_le_32(buf[ 0:4]);
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
	uint crc32;
	union {
		uint compress_size;
		ulong compress_size_zip64;
	}
	union {
		uint uncompress_size;
		ulong uncompress_size_zip64;
	}
}

fn void? ZipDataDescriptor.parse(&d, InStream in, bool zip64 = false)
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
		d.compress_size_zip64   = read_le_64(buf[ 4:8]);
		d.uncompress_size_zip64 = read_le_64(buf[12:8]);
	}
}

fn String? read_n(InStream f, usz n, Allocator allocator) @private => @pool()
{
	if (n == 0) return "";
	char[] buf = mem::talloc_array(char, n);
	usz read = 0;
	while (read < n)
	{
		read += f.read(buf[read : n - read])!;
	}
	return ((String)buf[:n]).copy(allocator);
}

<*
 Pack two bytes into a ushort (little-endian).

 @require p.len >= 2
*>
fn ushort read_le_16(char[] p) @inline @private
{
	return ((ushort) p[0]) | ((ushort) p[1] << 8);
}

<*
 Pack four bytes into an uint (little-endian).

 @require p.len >= 4
*>
fn uint read_le_32(char[] p) @inline @private
{
	return ((uint) p[0]) |
		((uint) p[1] << 8) |
		((uint) p[2] << 16) |
		((uint) p[3] << 24);
}

<*
 Pack eight bytes into an ulong (little-endian).

 @require p.len >= 8
*>
fn ulong read_le_64(char[] p) @inline @private
{
	return ((ulong) p[0]) |
		((ulong) p[1] << 8) |
		((ulong) p[2] << 16) |
		((ulong) p[3] << 24) |
		((ulong) p[4] << 32) |
		((ulong) p[5] << 40) |
		((ulong) p[6] << 48) |
		((ulong) p[7] << 56);
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

	return NOT_FOUND?;
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

	return NOT_FOUND?;
}
