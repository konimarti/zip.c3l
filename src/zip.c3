module zip;

import std::io;

const uint COMPRESS_METHOD_STORE = 0;
const uint COMPRESS_METHOD_DEFLATE = 8;

const char[*] MAGIC_NUMBER_EOCD = {0x50, 0x4b, 0x05, 0x06};
const char[*] MAGIC_NUMBER_CDFH = {0x50, 0x4b, 0x01, 0x02};
const char[*] MAGIC_NUMBER_LFH  = {0x50, 0x4b, 0x03, 0x04};

faultdef NOT_FOUND;

<*
*>
fn ushort? read_le_16(InStream in) @inline @private
{
	return ((ushort) in.read_byte()!) | ((ushort) in.read_byte()! << 8);
}

<*
*>
fn uint? read_le_32(InStream in) @inline @private
{
	return ((uint) in.read_byte()!) |
		((uint) in.read_byte()! << 8) |
		((uint) in.read_byte()! << 16) |
		((uint) in.read_byte()! << 24);
}

<*
 End of central directory record (EOCD)
*>
struct ZipEOCD (Printable)
{
	uint magic_number;
	ushort number_of_disk;
	ushort disk_start;
	ushort nr_records;
	ushort tot_nr_records;
	uint size_bytes; // size of central directory
	uint rel_offset; // relative to start of archive
	ushort comment_len;
	String comment; // comment.len == comment_len
	Allocator allocator;
}

fn void ZipEOCD.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.comment);
	*self = {};
}

fn usz? ZipEOCD.to_format(&self, Formatter *f) @dynamic
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
fn ZipEOCD? parse_eocd(InStream in, Allocator allocator = mem) => @pool()
{
	ZipEOCD eocd;

	eocd.magic_number   = read_le_32(in)!;
	eocd.number_of_disk = read_le_16(in)!;
	eocd.disk_start     = read_le_16(in)!;
	eocd.nr_records     = read_le_16(in)!;
	eocd.tot_nr_records = read_le_16(in)!;
	eocd.size_bytes     = read_le_32(in)!;
	eocd.rel_offset     = read_le_32(in)!;
	eocd.comment_len    = read_le_16(in)!;

	if (eocd.comment_len > 0)
	{
		char[] comment = mem::talloc_array(char, eocd.comment_len);
		in.read(comment)!;
		eocd.comment = ((String)comment).copy(allocator);
		eocd.allocator = allocator;
	}

	return eocd;
}

<*
 Central directory file header (CDFH)
*>
struct ZipCDFH
{
	uint magic_number;
	ushort version_used;
	ushort version_min;
	ushort flag;
	ushort compress_method;
	ushort last_mod_time;
	ushort last_mod_date;
	uint crc32; // of uncompressed data
	uint compress_size;
	uint uncompress_size;
	ushort filename_len; // n
	ushort extra_len; // m
	ushort comment_len; // k
	ushort disk_nr; // where file starts
	ushort internal_attr;
	uint external_attr;
	uint rel_offset; // relative offset of local file header
	String filename; // filename.len == n
	String extra; // extra.len == m
	String comment; // comment.len == k
	Allocator allocator;
}

fn void ZipCDFH.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.filename);
	allocator::free(self.allocator, self.extra);
	allocator::free(self.allocator, self.comment);
	*self = {};
}

fn ZipCDFH? parse_cdfh(InStream in, Allocator allocator = mem) => @pool()
{
	ZipCDFH cdfh;

	cdfh.magic_number    = read_le_32(in)!;
	cdfh.version_used    = read_le_16(in)!;
	cdfh.version_min     = read_le_16(in)!;
	cdfh.flag            = read_le_16(in)!;
	cdfh.compress_method = read_le_16(in)!;
	cdfh.last_mod_time   = read_le_16(in)!;
	cdfh.last_mod_date   = read_le_16(in)!;
	cdfh.crc32           = read_le_32(in)!;
	cdfh.compress_size   = read_le_32(in)!;
	cdfh.uncompress_size = read_le_32(in)!;
	cdfh.filename_len    = read_le_16(in)!;
	cdfh.extra_len       = read_le_16(in)!;
	cdfh.comment_len     = read_le_16(in)!;
	cdfh.disk_nr         = read_le_16(in)!;
	cdfh.internal_attr   = read_le_16(in)!;
	cdfh.external_attr   = read_le_32(in)!;
	cdfh.rel_offset      = read_le_32(in)!;

	if (cdfh.filename_len > 0)
	{
		char[] filename = mem::talloc_array(char, cdfh.filename_len);
		in.read(filename)!;
		cdfh.filename = ((String)filename).copy(allocator);
	}

	if (cdfh.extra_len > 0)
	{
		char[] extra = mem::talloc_array(char, cdfh.extra_len);
		in.read(extra)!;
		cdfh.extra = ((String)extra).copy(allocator);
	}

	if (cdfh.comment_len > 0)
	{
		char[] comment = mem::talloc_array(char, cdfh.comment_len);
		in.read(comment)!;
		cdfh.comment = ((String)comment).copy(allocator);
	}

	cdfh.allocator = allocator;

	return cdfh;
}

<*
 Local file header
*>
struct ZipLFH
{
	uint magic_number;
	ushort version_min;
	ushort flag;
	ushort compress_method;
	ushort last_mod_time;
	ushort last_mod_date;
	uint crc32; // of uncompressed data
	uint compress_size;
	uint uncompress_size;
	ushort filename_len; // n
	ushort extra_len; // m
	String filename; // filename.len == n
	String extra; // extra.len == m
	Allocator allocator;
}

fn void ZipLFH.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.filename);
	allocator::free(self.allocator, self.extra);
	*self = {};
}

fn ZipLFH? parse_lfh(InStream in, Allocator allocator = mem) => @pool()
{
	ZipLFH lfh;

	lfh.magic_number    = read_le_32(in)!;
	lfh.version_min     = read_le_16(in)!;
	lfh.flag            = read_le_16(in)!;
	lfh.compress_method = read_le_16(in)!;
	lfh.last_mod_time   = read_le_16(in)!;
	lfh.last_mod_date   = read_le_16(in)!;
	lfh.crc32           = read_le_32(in)!;
	lfh.compress_size   = read_le_32(in)!;
	lfh.uncompress_size = read_le_32(in)!;
	lfh.filename_len    = read_le_16(in)!;
	lfh.extra_len       = read_le_16(in)!;

	if (lfh.filename_len > 0)
	{
		char[] filename = mem::talloc_array(char, lfh.filename_len);
		in.read(filename)!;
		lfh.filename = ((String)filename).copy(allocator);
	}

	if (lfh.extra_len > 0)
	{
		char[] extra = mem::talloc_array(char, lfh.extra_len);
		in.read(extra)!;
		lfh.extra = ((String)extra).copy(allocator);
	}

	lfh.allocator = allocator;

	return lfh;
}

<*
 Scan from the end of the file for the end of central directory (EOCD) record
*>
fn usz? find_eocd_record(InStream in)
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

		// Scan for EOCD magic number
		if (try loc = ((String)buf[:n]).index_of((String)MAGIC_NUMBER_EOCD[:4]))
		{
			return size - offset + loc;
		}
	}

	return NOT_FOUND?;
}

// FIXME: unused
// fn usz? rindex_of(char[] buf, char[] sub)
// {
// 	usz needed = sub.len;
// 	if (needed > 0 && buf.len >= needed)
// 	{
// 		char first = sub[0];
// 		foreach_r (i, c : buf[..^needed])
// 		{
// 			if (c == first && buf[i : needed] == sub) return i;
// 		}
// 	}
// 	return NOT_FOUND?;
// }

fn void test_read_eocd_record() @test => @pool()
{
	char[*] file = {0x00,0x50,0x4B,0x05,0x06,0x00,0x00,0x00,0x00,
			     0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,
			     0x00,0x00,0x00,0x00,0x00,0x00};

	InStream in = (ByteReader){}.init(file[..]);
	// Find record
	usz loc = find_eocd_record(in)!!;
	assert(loc == 1);

	// Set file to the start of the eocd record
	in.seek(loc, Seek.SET)!!;

	// Parse record
	ZipEOCD record = parse_eocd(in)!!;
	assert(record.magic_number == 0x06054b50,
		"got: %d, but want: %d", record.magic_number, 0x06054b50);
	assert(record.size_bytes == 0x04030201,
		"got: %d, but want: %d", record.size_bytes, 0x04030201);
}
