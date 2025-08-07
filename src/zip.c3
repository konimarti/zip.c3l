module archive::zip;

import std::io;
import std::collections::pair;

import tinf::inflate;

const uint COMPRESS_METHOD_STORE   = 0;
const uint COMPRESS_METHOD_DEFLATE = 8;
const uint COMPRESS_METHOD_BZIP2   = 12; // TODO: unsupported

const char[*] MAGIC_NUMBER_END     = {0x50, 0x4b, 0x05, 0x06};
const char[*] MAGIC_NUMBER_CENTRAL = {0x50, 0x4b, 0x01, 0x02};
const char[*] MAGIC_NUMBER_LOCAL   = {0x50, 0x4b, 0x03, 0x04};

faultdef NOT_FOUND, INVALID_END_RECORD, INVALID_CENTRAL_FILE_HEADER,
	INVALID_LOCAL_FILE_HEADER, MAGIC_NUMBER_MISMATCH,
	UNSUPPORTED_COMPRESSION_METHOD;

alias ZipFile = Pair{ ZipCentralFileHeader, ZipLocalFileHeader };

<*
 End of central directory record (EOCD)
*>
struct Zip (Printable)
{
	ZipEndRecord 	       record;
	ZipCentralFileHeader[] central_headers;
	ZipLocalFileHeader[]   local_headers;
	Allocator	       allocator;
}

fn void? Zip.parse(&z, InStream file, Allocator allocator)
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
	foreach (i, &local_header : z.local_headers)
	{
		file.seek(z.central_headers[i].rel_offset, Seek.SET)!;
		local_header.parse(file, allocator)!;
	}
}

fn void Zip.free(&z)
{
	if (!z.allocator) return;

	z.record.free();

	foreach (&c : z.central_headers) c.free();
	allocator::free(z.allocator, z.central_headers);

	foreach (&l : z.local_headers) l.free();
	allocator::free(z.allocator, z.local_headers);

	*z = {};
}

fn usz? Zip.to_format(&z, Formatter *f) @dynamic
{
	// TODO: Not implemented yet.
	return 0;
}

fn usz Zip.len(&z) @operator(len)
{
	return z.record.tot_nr_records;
}

fn ZipFile Zip.get(&z, usz index) @operator([])
{
	return {z.central_headers[index], z.local_headers[index]};
}

<*
 Returns an InStream to read the compressed data for the given file.
 Don't close the returned InStream.
*>
fn InStream? ZipFile.compressed_data(&zf, InStream file)
{
	ZipCentralFileHeader cf;
	ZipLocalFileHeader lf;

	zf.unpack(&cf, &lf);

	uint loc = cf.rel_offset + 30 + lf.filename_len + lf.extra_len;
	file.seek(loc, Seek.SET)!;

	return (LimitReader){}.init(file, lf.compress_size);
}

<*
 Decompress data and write it to OutStream out.
*>
fn usz? ZipFile.copy_to(&zf, InStream file, OutStream out)
{
	switch (zf.first.compress_method)
	{
		case COMPRESS_METHOD_STORE:
			return io::copy_to(zf.compressed_data(file), out);
		case COMPRESS_METHOD_DEFLATE:
			@pool() {
				char[] src = mem::temp_array(char, zf.first.compress_size);
				io::read_all(zf.compressed_data(file), src)!;

				char[] dst = mem::temp_array(char, zf.first.uncompress_size);
				inflate::uncompress(dst, src)!;

				return io::copy_to(&&io::wrap_bytes(dst), out);
			};
		case COMPRESS_METHOD_BZIP2:
		default:
			return UNSUPPORTED_COMPRESSION_METHOD?;
	}
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

	r.magic_number   = read_le_32(buf[ 0:4])!;
	r.number_of_disk = read_le_16(buf[ 4:2])!;
	r.disk_start     = read_le_16(buf[ 6:2])!;
	r.nr_records     = read_le_16(buf[ 8:2])!;
	r.tot_nr_records = read_le_16(buf[10:2])!;
	r.size_bytes     = read_le_32(buf[12:4])!;
	r.rel_offset     = read_le_32(buf[16:4])!;
	r.comment_len    = read_le_16(buf[20:2])!;
	r.comment        = read_n(in, r.comment_len, allocator)!;
	r.allocator      = allocator;
}

<*
 Central directory file header (CDFH)
*>
struct ZipCentralFileHeader
{
	uint      magic_number;
	ushort    version_used;
	ushort    version_min;
	ushort    flag;
	ushort    compress_method;
	ushort    last_mod_time;
	ushort    last_mod_date;
	uint      crc32;		// of uncompressed data
	uint      compress_size;
	uint      uncompress_size;
	ushort    filename_len; 	// n
	ushort    extra_len; 		// m
	ushort    comment_len; 		// k
	ushort    disk_nr; 		// where file starts
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

	c.magic_number    = read_le_32(buf[ 0:4])!;
	c.version_used    = read_le_16(buf[ 4:2])!;
	c.version_min     = read_le_16(buf[ 6:2])!;
	c.flag            = read_le_16(buf[ 8:2])!;
	c.compress_method = read_le_16(buf[10:2])!;
	c.last_mod_time   = read_le_16(buf[12:2])!;
	c.last_mod_date   = read_le_16(buf[14:2])!;
	c.crc32           = read_le_32(buf[16:4])!;
	c.compress_size   = read_le_32(buf[20:4])!;
	c.uncompress_size = read_le_32(buf[24:4])!;
	c.filename_len    = read_le_16(buf[28:2])!;
	c.extra_len       = read_le_16(buf[30:2])!;
	c.comment_len     = read_le_16(buf[32:2])!;
	c.disk_nr         = read_le_16(buf[34:2])!;
	c.internal_attr   = read_le_16(buf[36:2])!;
	c.external_attr   = read_le_32(buf[38:4])!;
	c.rel_offset      = read_le_32(buf[42:4])!;
	c.filename        = read_n(in, c.filename_len, allocator)!;
	c.extra           = read_n(in, c.extra_len, allocator)!;
	c.comment         = read_n(in, c.comment_len, allocator)!;
	c.allocator       = allocator;
}

<*
 Local file header
*>
struct ZipLocalFileHeader
{
	uint      magic_number;
	ushort    version_min;
	ushort    flag;
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

	if (buf[:4] != MAGIC_NUMBER_LOCAL[:4]) return MAGIC_NUMBER_MISMATCH?;

	f.magic_number    = read_le_32(buf[ 0:4])!;
	f.version_min     = read_le_16(buf[ 4:2])!;
	f.flag            = read_le_16(buf[ 6:2])!;
	f.compress_method = read_le_16(buf[ 8:2])!;
	f.last_mod_time   = read_le_16(buf[10:2])!;
	f.last_mod_date   = read_le_16(buf[12:2])!;
	f.crc32           = read_le_32(buf[14:4])!;
	f.compress_size   = read_le_32(buf[18:4])!;
	f.uncompress_size = read_le_32(buf[22:4])!;
	f.filename_len    = read_le_16(buf[26:2])!;
	f.extra_len       = read_le_16(buf[28:2])!;
	f.filename        = read_n(in, f.filename_len, allocator)!;
	f.extra           = read_n(in, f.extra_len, allocator)!;
	f.allocator       = allocator;
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
fn ushort? read_le_16(char[] p) @inline @private
{
	return ((ushort) p[0]) | ((ushort) p[1] << 8);
}

<*
 Pack four bytes into an uint (little-endian).

 @require p.len >= 4
*>
fn uint? read_le_32(char[] p) @inline @private
{
	return ((uint) p[0]) |
		((uint) p[1] << 8) |
		((uint) p[2] << 16) |
		((uint) p[3] << 24);
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
