<*
 Archive::zip provides the functionality to handle the ZIP format.

 ZIP specification: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
 AES encryption:    https://www.winzip.com/en/support/aes-encryption/

*>
module archive::zip;

import std::io;
import std::collections::pair;
import std::hash::crc32;

import tinf::inflate;

alias CompressMethod = uint;
const CompressMethod COMPRESS_METHOD_STORE   = 0;
const CompressMethod COMPRESS_METHOD_DEFLATE = 8;
const CompressMethod COMPRESS_METHOD_BZIP2   = 12; // TODO: unsupported
const CompressMethod COMPRESS_METHOD_ZSTD    = 93; // TODO: unsupported
const CompressMethod COMPRESS_METHOD_MP3     = 94; // TODO: unsupported
const CompressMethod COMPRESS_METHOD_XZ      = 95; // TODO: unsupported
const CompressMethod COMPRESS_METHOD_JPEG    = 96; // TODO: unsupported
const CompressMethod COMPRESS_METHOD_AEX     = 99; // TODO: unsupported

const char[*] MAGIC_NUMBER_CENTRAL = {0x50, 0x4b, 0x01, 0x02};
const char[*] MAGIC_NUMBER_LOCAL   = {0x50, 0x4b, 0x03, 0x04};
const char[*] MAGIC_NUMBER_END     = {0x50, 0x4b, 0x05, 0x06};
const char[*] MAGIC_NUMBER_DESCR   = {0x50, 0x4b, 0x07, 0x08}; // optional

faultdef NOT_FOUND,
	INVALID_END_RECORD,
	INVALID_CENTRAL_FILE_HEADER,
	INVALID_LOCAL_FILE_HEADER,
	INVALID_DATA_DESCRIPTOR,
	INVALID_CRC32_HASH,
	MAGIC_NUMBER_MISMATCH,
	UNSUPPORTED_COMPRESSION_METHOD,
	UNSUPPORTED_ZIP64;

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
		filename = zip_file.filename();
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


alias ZipFile = Pair{ ZipCentralFileHeader, ZipLocalFileHeader };

<*
 Store the metadata for a zip archive. Metadata includes local and central file
 headers and end records.
*>
struct ZipMeta (Printable)
{
	ZipEndRecord 	       record;
	ZipCentralFileHeader[] central_headers;
	ZipLocalFileHeader[]   local_headers;
	Allocator	       allocator;
}

fn void? ZipMeta.tparse(&z, InStream file) => z.parse(file, tmem);
fn void? ZipMeta.parse(&z, InStream file, Allocator allocator)
{
	usz nrecords, end_record_loc;

	end_record_loc = find_end_record(file)!;
	file.seek(end_record_loc, Seek.SET)!;

	z.allocator = allocator;
	defer catch z.free();

	z.record.parse(file, allocator)!;

	nrecords = z.record.tot_nr_records;
	z.central_headers = allocator::new_array(allocator, ZipCentralFileHeader, nrecords);
	z.local_headers = allocator::new_array(allocator, ZipLocalFileHeader, nrecords);

	// Read central file headers
	file.seek(z.record.rel_offset, Seek.SET)!;
	foreach (&central_header : z.central_headers)
	{
		central_header.parse(file, allocator)!;
	}

	// Read local file headers
	usz offset;
	foreach (i, &local_header : z.local_headers)
	{
		offset = z.central_headers[i].rel_offset;
		file.seek(offset, Seek.SET)!;
		local_header.parse(file, allocator)!;
		if (local_header.flag.use_descriptor)
		{
			offset += z.central_headers[i].compress_size; // TODO: make a function that can handle zip64?
			file.seek(offset, Seek.SET)!;
			local_header.data_descriptor.parse(file)!;
		}
	}
}

fn void ZipMeta.free(&z)
{
	if (!z.allocator) return;

	z.record.free();

	foreach (&c : z.central_headers) c.free();
	allocator::free(z.allocator, z.central_headers);

	foreach (&l : z.local_headers) l.free();
	allocator::free(z.allocator, z.local_headers);

	*z = {};
}

fn usz? ZipMeta.to_format(&z, Formatter *f) @dynamic
{
	// TODO: Not implemented yet.
	return 0;
}

fn usz ZipMeta.len(&z) @operator(len)
{
	return z.record.tot_nr_records;
}

fn ZipFile ZipMeta.get(&z, usz index) @operator([])
{
	return {z.central_headers[index], z.local_headers[index]};
}

fn usz? ZipFile.to_format(&zf, Formatter *f) @dynamic
{
	return f.printf("%-40s %-12d %-12d %-12d\n",
			zf.filename(), zf.compressed_size(), zf.uncompressed_size(), zf.compression_method());
}

<*
 Filename with forward slash ('/') as separator according to 4.4.16 of the spec.

 TODO: Check for unicode filename (bit 11 in flags or extra fields)
*>
fn String ZipFile.filename(&zf) => zf.first.filename;

<*
 Compressed Size (as it is stored in Zip archive).
*>
fn usz ZipFile.compressed_size(&zf) => (usz)zf.first.compress_size;

<*
 Uncompressed Size (after extraction and uncompression).
*>
fn usz ZipFile.uncompressed_size(&zf) => (usz)zf.first.uncompress_size;

<*
 CRC32 of uncompressed data.
*>
fn uint ZipFile.crc32(&zf) => zf.first.crc32;

<*
 CRC32 of uncompressed data.

 @require zf.first.compress_method == zf.second.compress_method : "Inconsistent compression method between Center and Local file headers"
*>
fn CompressMethod ZipFile.compression_method(&zf) => (usz)zf.first.compress_method;

<*
 Returns a LimitReader for the compressed (!) data of the ZipFile.
 Do not close the LimitReader.
 @param [in] file : "Zip archive file stream"
*>
fn LimitReader? ZipFile.reader(&zf, InStream file)
{
	ZipCentralFileHeader cf;
	ZipLocalFileHeader lf;
	zf.unpack(&cf, &lf);

	uint loc = cf.rel_offset + 30 + lf.filename_len + lf.extra_len;
	file.seek(loc, Seek.SET)!;

	return { file, lf.compress_size };
}

<*
 Decompress data and write it to OutStream out.
*>
fn usz? ZipFile.copy_to(&zf, InStream file, OutStream writer) => @pool()
{
	char[] src, dst;

	dst = mem::temp_array(char, zf.uncompressed_size());

	switch (zf.compression_method())
	{
	case COMPRESS_METHOD_STORE:
		assert(zf.compressed_size() == zf.uncompressed_size(),
			"COMPRESS_METHOD_STORE: uncompressed and compressed sizes differ");

		// Read all data from limit reader
		io::read_all(&&zf.reader(file), dst)!;

	case COMPRESS_METHOD_DEFLATE:
		assert(zf.compressed_size() != zf.uncompressed_size(),
			"COMPRESS_METHOD_DEFLATE: uncompressed and compressed sizes match");

		// Read all data from limit reader
		src = mem::temp_array(char, zf.compressed_size());
		io::read_all(&&zf.reader(file), src)!;

		// Uncompress data
		inflate::uncompress(dst, src)!;

	case COMPRESS_METHOD_BZIP2:
	default:
		return UNSUPPORTED_COMPRESSION_METHOD?;
	}

	// Verify crc32 hash
	if (crc32::hash(dst) != zf.crc32()) return INVALID_CRC32_HASH?;

	// Write data
	return io::write_all(writer, dst);
}

<*
 End of central directory record (EOCD)
*>
struct ZipEndRecord (Printable)
{
	uint	  magic_number;
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
	n += f.printf("magic num : %x\n", self.magic_number)!;
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

	if (buf[:4] != MAGIC_NUMBER_END[:4]) return MAGIC_NUMBER_MISMATCH?;

	r.magic_number   = read_le_32(buf[ 0:4]);
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
	bool encrypted      :  0;	// indicates if file is encrypted
	bool use_descriptor :  3;	// crc32, sizes are unset; use Data Descriptor
	bool efs            : 11;	// language encoding flag
}

<*
 Central directory file header (CDFH)

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
	uint      magic_number;
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

	if (buf[:4] != MAGIC_NUMBER_CENTRAL[:4]) return MAGIC_NUMBER_MISMATCH?;

	c.magic_number    = read_le_32(buf[ 0:4]);
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
	uint      magic_number;
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

	ZipDataDescriptor data_descriptor;
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

	if (buf[:4] != MAGIC_NUMBER_LOCAL[:4]) return MAGIC_NUMBER_MISMATCH?;

	f.magic_number    = read_le_32(buf[ 0:4]);
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
 Scan from the end of the file for the end of central directory (EOCD) record
*>
fn usz? find_end_record(InStream in)
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
		if (try loc = ((String)buf[:n]).index_of(MAGIC_NUMBER_END[:4]))
		{
			return size - offset + loc;
		}
	}

	return NOT_FOUND?;
}
