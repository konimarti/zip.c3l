module archive::zip;

import std::io, std::time, std::collections::list, std::hash::crc32;
import compress::flate;

alias ZipEntryList = List { ZipEntry };

struct ZipWriter
{
	Allocator    allocator;
	ZipEntryList entries;
	ByteCounterStream writer;
}

fn ZipWriter*? ZipWriter.init(&self, Allocator allocator, OutStream writer)
{
	self.allocator = allocator;
	self.writer    = (ByteCounterStream){ writer, 0 };
	self.entries.init(allocator);
	return self;
}

fn void? ZipWriter.close(&self)
{
	// Now we need to create the central directory.
	usz offset_directory = self.writer.tell();
	foreach (&entry: self.entries)
	{
		self.write_central_directory_header(entry)!;
	}
	usz size_directory = self.writer.tell() - offset_directory;

	if (self.entries.len() > ushort.max ||
		offset_directory > uint.max ||
		size_directory > uint.max)
	{
		usz offset_eoc64 = self.writer.tell();
		self.write_zip64_end_record(offset_directory, size_directory)!;
		self.write_zip64_end_locator(offset_eoc64)!;
	}

	// And finally, the End of Directory Record.
	self.write_end_record(offset_directory, size_directory)!;
}

fn void ZipWriter.free(&self)
{
	foreach (entry: self.entries) entry.free();
	self.entries.free();
	*self = {};
}

<*
 Write a file with filename and content to the zip file with the given
 compression method.

 The caller of this function should ensure that the filename follows the zip
 specification (no leading slash and trailing slash for directories).
*>
fn ZipEntry? ZipWriter.write_buffer(&self, String filename, char[] content,
	ZipCompressMethod compress_method = COMPRESS_STORE)
{
	char[] compressed;
	switch (compress_method)
	{
		case COMPRESS_STORE:   compressed = content;
		case COMPRESS_DEFLATE: compressed = flate::tcompress(content)!;
		default: return UNSUPPORTED_COMPRESSION~;
	}

	ZipEntry entry;
	entry.init_with_buffer(self.allocator, filename, content,
		compressed, compress_method)!;

	// Store local date and time.
	entry.set_date_time(datetime::now().to_local());

 	// Store offset to Local File Header.
	entry.rel_offset = self.writer.tell();

	// Re-format to ZIP64 if needed.
	entry.add_zip64_extra_field()!;

	// Write local file header.
	self.write_local_file_header(&entry)!;

	// Save position after header as file_offset.
	entry.file_offset = self.writer.tell();

	// Only write content if it is not a directory and if there is data.
	if (compressed.len > 0)
	{
		self.writer.write(compressed)!;
	}

	// Store ZipEntry since We need it for the central directory
	self.entries.push(entry);

	return entry;
}

fn void? ZipWriter.write_local_file_header(&self, ZipEntry *entry)
{
	 write_le_32(&self.writer, read_le_32(SIGNATURE_LOCAL[:4]))!;
	 write_le_16(&self.writer, (ushort)entry.version_min)!;
	 write_le_16(&self.writer, (ushort)entry.flag)!;
	 write_le_16(&self.writer, (ushort)entry.compress_method)!;
	 write_le_16(&self.writer, (ushort)entry.time.last_mod_time)!;
	 write_le_16(&self.writer, (ushort)entry.date.last_mod_date)!;
	 write_le_32(&self.writer, (uint)entry.crc32)!;
	 write_le_32(&self.writer, (uint)entry.compress_size)!;
	 write_le_32(&self.writer, (uint)entry.uncompress_size)!;
	 write_le_16(&self.writer, (ushort)entry.filename.len)!;
	 write_le_16(&self.writer, (ushort)entry.extra.len)!;

	 if (entry.filename.len) self.writer.write(entry.filename)!;
	 if (entry.extra.len) self.writer.write(entry.extra)!;
}

fn void? ZipWriter.write_central_directory_header(&self, ZipEntry *entry)
{
	 write_le_32(&self.writer, read_le_32(SIGNATURE_CENTRAL[:4]))!;
	 write_le_16(&self.writer, (ushort)entry.version_used)!;
	 write_le_16(&self.writer, (ushort)entry.version_min)!;
	 write_le_16(&self.writer, (ushort)entry.flag)!;
	 write_le_16(&self.writer, (ushort)entry.compress_method)!;
	 write_le_16(&self.writer, (ushort)entry.time.last_mod_time)!;
	 write_le_16(&self.writer, (ushort)entry.date.last_mod_date)!;
	 write_le_32(&self.writer, (uint)entry.crc32)!;
	 write_le_32(&self.writer, (uint)entry.compress_size)!;
	 write_le_32(&self.writer, (uint)entry.uncompress_size)!;
	 write_le_16(&self.writer, (ushort)entry.filename.len)!;
	 write_le_16(&self.writer, (ushort)entry.extra.len)!;
	 write_le_16(&self.writer, 0)!;
	 write_le_16(&self.writer, 0)!;
	 write_le_16(&self.writer, 0)!;
	 write_le_32(&self.writer, 0)!;
	 write_le_32(&self.writer, (uint)entry.rel_offset)!;

	 if (entry.filename.len) self.writer.write(entry.filename)!;
	 if (entry.extra.len) self.writer.write(entry.extra)!;
}

fn void? ZipWriter.write_end_record(&self, usz offset, usz size_directory)
{
	 write_le_32(&self.writer, read_le_32(SIGNATURE_END[:4]))!;
	 write_le_16(&self.writer, 0)!;
	 write_le_16(&self.writer, 0)!;
	 write_le_16(&self.writer, (ushort)self.entries.len())!;
	 write_le_16(&self.writer, (ushort)self.entries.len())!;
	 write_le_32(&self.writer, (uint)size_directory)!;
	 write_le_32(&self.writer, (uint)offset)!;
	 write_le_16(&self.writer, 0)!;
}

fn void? ZipWriter.write_zip64_end_record(&self, usz offset, usz size_directory)
{
	 write_le_32(&self.writer, read_le_32(SIGNATURE_END_ZIP64[:4]))!;
	 write_le_64(&self.writer, 56-12)!; // Size of this record (EOCD64) - 12
	 write_le_16(&self.writer, 0)!; // Version made
	 write_le_16(&self.writer, 0)!; // Version min
	 write_le_32(&self.writer, 0)!; // Number of disk
	 write_le_32(&self.writer, 0)!; // Disk start
	 write_le_64(&self.writer, (ulong)self.entries.len())!;
	 write_le_64(&self.writer, (ulong)self.entries.len())!;
	 write_le_64(&self.writer, (uint)size_directory)!;
	 write_le_64(&self.writer, (uint)offset)!;
}

fn void? ZipWriter.write_zip64_end_locator(&self, usz offset_eocd64)
{
	 write_le_32(&self.writer, read_le_32(SIGNATURE_LOCATOR_ZIP64[:4]))!;
	 write_le_32(&self.writer, 0)!; // Disk start of EOCD64.
	 write_le_64(&self.writer, (ulong)offset_eocd64)!;
	 write_le_32(&self.writer, 0)!;
}

fn void? write_le_16(OutStream w, ushort s) @inline => io::write_le_short(w, s);
fn void? write_le_32(OutStream w, uint s)   @inline => io::write_le_int(w, s);
fn void? write_le_64(OutStream w, ulong s)  @inline => io::write_le_long(w, s);

<*
 ByteCounterStream wraps an OutStream and counts the number of written bytes.
*>
struct ByteCounterStream (OutStream)
{
	OutStream w;
	ulong written;
}

fn ulong ByteCounterStream.tell(&self) => self.written;

fn usz? ByteCounterStream.write(&self, char[] bytes) @dynamic
{
	usz n = self.w.write(bytes)!;
	self.written += n;
	return n;
}

fn void? ByteCounterStream.write_byte(&self, char c) @dynamic
{
	self.w.write_byte(c)!;
	self.written++;
}
