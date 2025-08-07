module archive::zip;

import std::io;
import std::hash::crc32;

faultdef INVALID_ZIP64_EXTRA_FIELD,
	INVALID_UNICODE_PATH_EXTRA_FIELD;

const ushort ZIP64_EXTRA_HEADER  = 0x0001;
const ushort UNICODE_PATH_HEADER = 0x7075;

<*
 Iterate through the extra fields of a Local File Header.

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

faultdef INVALID_EXTRA_FIELD_LENGTH;

<*
 Returns the next extra block.
*>
fn char[]? ExtraFieldIterator.next(&self)
{
	if (self.index + 4 >= self.extra.len || self.extra.len < 4) return io::EOF?;
	ushort len = read_le_16(self.extra[self.index+2:2]) + 4;

	if (self.index + len > self.extra.len) return INVALID_EXTRA_FIELD_LENGTH?;
	char[] next = self.extra[self.index:len];

	self.index += len;

	return next;
}

<*
 Find specific header and return it.

 @!return NOT_FOUND
*>
fn char[]? find_extra_header(char[] extra, ushort id)
{
	ExtraFieldIterator it = { extra, 0 };
	while (try data = it.next())
	{
		if (is_extra_header(data, id)) return data;
	}
	return NOT_FOUND?;
}

<*
 Checks if data block starts with header_id
*>
fn bool is_extra_header(char[] data, ushort header_id) @inline
{
	if (data.len < 2) return false;
	return read_le_16(data[:2]) == header_id;
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

fn void? Zip64ExtraField.parse(&f, char[] extra)
{
	if (extra.len < 4 && (extra.len >= 2 && read_le_16(extra[0:2]) != ZIP64_EXTRA_HEADER))
	{
		return INVALID_ZIP64_EXTRA_FIELD?;
	}

	usz len = read_le_16(extra[2:2]);

	f.header_id       = read_le_16(extra[ 0:2]);
	f.data_size       = read_le_16(extra[ 2:2]);
	f.uncompress_size = read_le_64(extra[ 4:8]);

	if (len < 16) return;
	f.compress_size   = read_le_64(extra[12:8]);

	if (len < 24) return;
	f.rel_offset      = read_le_64(extra[20:8]);

	if (len < 32) return;
	f.number          = read_le_32(extra[28:4]);
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
	char[] unicode;
}

fn void? UnicodePathExtraField.parse(&f, char[] extra)
{
	if (extra.len < 9 ||
		(extra.len >= 2 && read_le_16(extra[0:2]) != UNICODE_PATH_HEADER))
	{
		return INVALID_UNICODE_PATH_EXTRA_FIELD?;
	}

	f.header_id = read_le_16(extra[0:2]);
	f.data_size = read_le_16(extra[2:2]);
	f.version   =            extra[4];
	f.crc32     = read_le_32(extra[5:4]);
	f.unicode   =            extra[9..];

	if (crc32::hash(f.unicode) != f.crc32) return INVALID_CRC32_HASH?;
}
