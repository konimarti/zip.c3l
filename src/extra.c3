module archive::zip;
import std::io, std::hash::crc32;

faultdef INVALID_EXTRA_FIELD_LENGTH,
	 INVALID_ZIP64_EXTRA_FIELD,
	 INVALID_UNICODE_PATH_EXTRA_FIELD;

const ushort ZIP64_EXTRA_HEADER  = 0x0001;
const ushort UNICODE_PATH_HEADER = 0x7075;

<*
 Iterator over the extra fields of a Local File Header.

 4.5.1 In order to allow different programs and different types
 of information to be stored in the 'extra' field in .ZIP
 files, the following structure MUST be used for all
 programs storing data in this field:

 	header1+data1 + header2+data2 . . .

 Each header MUST consist of:

 	Header ID - 2 bytes
 	Data Size - 2 bytes

 Note: all fields stored in Intel low-byte/high-byte order.

 The Header ID field indicates the type of data that is in the following data block.

*>
struct ExtraFieldIterator
{
	char[] extra;
	usz    index;
}

struct ExtraField
{
	ushort header_id;
	ushort payload_len;
	char[] payload;
}

<*
 Returns the next extra block.
*>
fn ExtraField? ExtraFieldIterator.next(&self)
{
	const usz HEADER_SIZE = 4;
	if (self.index + HEADER_SIZE >= self.extra.len || self.extra.len < HEADER_SIZE)
	{
		return io::EOF~;
	}
	ExtraField field = parse_extra_field(self.extra[self.index..])!;
	self.index += HEADER_SIZE + field.payload_len;
	return field;
}

fn ExtraField? parse_extra_field(char[] extra)
{
	usz n = extra.len;
	if (n < 4) return INVALID_EXTRA_FIELD_LENGTH~;
	ushort id  = read_le_16(extra[0:2]);
	ushort len = read_le_16(extra[2:2]);
	if (n < 4 + len) return INVALID_EXTRA_FIELD_LENGTH~;
	char[] chunk = extra[4:len];
	return { .header_id = id, .payload_len = len, .payload = chunk };
}

<*
 Find an extra field for the given header_id in the extra array. Return the
 ExtraField.

 @return "ExtraField struct containing parsed header and payload data."
 @return? NOT_FOUND
*>
fn ExtraField? find_extra_field(char[] extra, ushort header_id)
{
	ExtraFieldIterator it = { extra, 0 };
	while (try field = it.next())
	{
		if (field.header_id == header_id) return field;
	}
	return NOT_FOUND~;
}

<*
 ZIP64 Extended Information Extra Field.

 Extra field is stored in the Local File Header.

 Value      		Size       Description
 -----      		----       -----------
 0x0001     		2 bytes    Tag for this "extra" block type
 Size       		2 bytes    Size of this "extra" block
 Original Size     	8 bytes    Original uncompressed file size
 Compressed Size     	8 bytes    Size of compressed data
 Relative Header Offset 8 bytes    Offset of local header record
 Disk Start Number     	4 bytes    Number of the disk on which this file starts

*>
struct Zip64ExtraField
{
	ushort header_id; 	// should be 0x0001
	ushort data_size; 	// size of "extra" block
        ulong  uncompress_size;
	ulong  compress_size;
        ulong  rel_offset;
	uint   number;
}

fn void? Zip64ExtraField.unpack(&self, ExtraField extra)
{
	if (extra.header_id != ZIP64_EXTRA_HEADER)
	{
		return INVALID_ZIP64_EXTRA_FIELD~;
	}

	self.header_id       = extra.header_id;
	self.data_size       = extra.payload_len;
	self.uncompress_size = read_le_64(extra.payload[ 0:8]);

	usz len = self.data_size;
	if (len < 16) return;
	self.compress_size   = read_le_64(extra.payload[8:8]);

	if (len < 24) return;
	self.rel_offset      = read_le_64(extra.payload[16:8]);

	if (len < 28) return;
	self.number          = read_le_32(extra.payload[24:4]);
}

fn void? Zip64ExtraField.pack(&self, char[] extra)
{
	ByteWriter *writer = (ByteWriter){}.init_with_buffer(extra);
	write_le_16(writer, self.header_id)!;
	write_le_16(writer, self.data_size)!;
	write_le_64(writer, self.uncompress_size)!;
	usz len = self.data_size;
	if (len < 16) return;
	write_le_64(writer, self.compress_size)!;
	if (len < 24) return;
	write_le_64(writer, self.rel_offset)!;
	if (len < 32) return;
	write_le_32(writer, self.number)!;
}

<*
 4.6.9 Unicode Path Extra Field

 Extra field is stored in the Local File Header.

 Value         Size       Description
 -----         ----       -----------
 0x7075        Short      tag for this extra block type ("up")
 TSize         Short      total data size for this block
 Version       1 byte     version of this extra field, currently 1
 NameCRC32     4 bytes    File Name Field CRC32 Checksum
 UnicodeName   Variable   UTF-8 version of the entry File Name

*>
struct UnicodePathExtraField
{
	ushort header_id; 	// should be 0x7075
	ushort data_size; 	// size of "extra" block
        char   version;
	uint   crc32;	        // file name checksum
	String filename; 	// UnicodeName
}

fn void? UnicodePathExtraField.unpack(&self, ExtraField extra)
{
	if (extra.header_id != UNICODE_PATH_HEADER)
	{
		return INVALID_UNICODE_PATH_EXTRA_FIELD~;
	}

	self.header_id = extra.header_id;
	self.data_size = extra.payload_len;
	self.version   =            extra.payload[0];
	self.crc32     = read_le_32(extra.payload[1:4]);
	self.filename  =    (String)extra.payload[5..];

	if (crc32::hash(self.filename) != self.crc32) return INVALID_CRC32_HASH~;
}
