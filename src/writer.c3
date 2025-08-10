module archive::zip;

import std::io, std::time;
import std::collections::list;
import std::hash::crc32;

alias ZipEntryList = List { ZipEntry };

struct ZipWriter
{
	Path         base_path;
	ZipOutStream writer;
	ZipEntryList entries;
	Allocator    allocator;
}

fn ZipWriter? ZipWriter.init(&p, Allocator allocator, String path, OutStream writer)
{
	p.allocator = allocator;
	p.base_path = path::new(allocator, path)!;
	p.writer    = (ZipOutStream){ writer, 0 };

	p.entries.init(allocator);

	return *p;
}

fn void? ZipWriter.close(&w)
{
	// Now we need to create the central directory.
	usz offset_directory = w.writer.tell();
	foreach (entry : w.entries)
	{
		entry.write_central_directory_header(&w.writer)!;
	}

	// And finally the End of Directory Record
	w.write_end_record(offset_directory)!;

	// Release resources
	w.free();
}

fn void ZipWriter.free(&w)
{
	foreach (entry : w.entries) entry.free();
	w.base_path.free();
	w.entries.free();
	*w = {};
}


// TODO: Move to ZipEntry struct
fn ZipEntry*? ZipEntry.init_with_buffer(&entry,
	Allocator allocator, String filename, char[] content,
	ZipCompressMethod compress_method = COMPRESS_STORE)
{
	entry.version_min     = 0; 			// TODO
	entry.flag.language   = true; 			// We are only using utf-8 strings
	entry.compress_method = compress_method;
	entry.crc32 	      = crc32::hash(content); 	// crc32 should be done on the compressed data, but we do a shortcut here.
	entry.compress_size   = content.len;		// TODO: Make zip64 compatible
	entry.uncompress_size = content.len;		// TODO: Make zip64 compatible
	entry.filename        = filename.copy(allocator);

	entry.version_used    = 0; // TODO
	entry.internal_attr   = 0;
	entry.external_attr   = 0;

	entry.allocator       = allocator;

	return entry;
}

<*
 Add content to the zip file.

 The caller of this function should ensure that the filename follows the zip
 specification (no leading slash and trailing slash for directories).
*>
fn void? ZipWriter.add_buffer(&w, String filename, char[] content,
	ZipCompressMethod compress_method = COMPRESS_STORE)
{
	ZipEntry entry = *(ZipEntry){}.init_with_buffer(w.allocator, filename,
		content, compress_method)!;

	// Store local date and time
	entry.set_date_time(datetime::now().to_local());

 	// Store offset to Local File Header
	entry.rel_offset = w.writer.tell();

	// Re-format to ZIP64 if needed
	entry.format_zip64()!;

	// Write local file header
	entry.write_local_file_header(&w.writer)!;

	// Save position after header as file_offset
	entry.file_offset = w.writer.tell();

	// Only write content if it is not a directory and if there is data.
	if (content.len > 0)
	{
		// TODO: should be the compressed data
		w.writer.write(content)!;

		// Release content mem
		allocator::free(mem, content.ptr);
	}

	// Store ZipEntry since We need it for the central directory
	w.entries.push(entry);
}

fn void? ZipEntry.write_local_file_header(&z, OutStream writer)
{
	 write_le_32(writer, read_le_32(SIGNATURE_LOCAL[:4]))!;
	 write_le_16(writer, (ushort)z.version_min    )!;
	 write_le_16(writer, (ushort)z.flag   )!;
	 write_le_16(writer, (ushort)z.compress_method)!;
	 write_le_16(writer, (ushort)z.time.last_mod_time  )!;
	 write_le_16(writer, (ushort)z.date.last_mod_date  )!;
	 write_le_32(writer, (uint)z.crc32          )!;
	 write_le_32(writer, (uint)z.compress_size  )!;
	 write_le_32(writer, (uint)z.uncompress_size)!;
	 write_le_16(writer, (ushort)z.filename.len   )!;
	 write_le_16(writer, (ushort)z.extra.len      )!;

	 if (z.filename.len) writer.write(z.filename)!;
	 if (z.extra.len) writer.write(z.extra)!;
}

fn void? ZipEntry.write_central_directory_header(&z, OutStream writer)
{
	 write_le_32(writer, read_le_32(SIGNATURE_CENTRAL[:4]))!;
	 write_le_16(writer, (ushort)z.version_used)!;
	 write_le_16(writer, (ushort)z.version_min)!;
	 write_le_16(writer, (ushort)z.flag)!;
	 write_le_16(writer, (ushort)z.compress_method)!;
	 write_le_16(writer, (ushort)z.time.last_mod_time)!;
	 write_le_16(writer, (ushort)z.date.last_mod_date)!;
	 write_le_32(writer, (uint)z.crc32)!;
	 write_le_32(writer, (uint)z.compress_size)!;
	 write_le_32(writer, (uint)z.uncompress_size)!;
	 write_le_16(writer, (ushort)z.filename.len)!;
	 write_le_16(writer, (ushort)z.extra.len)!;
	 write_le_16(writer, 0)!;
	 write_le_16(writer, 0)!;
	 write_le_16(writer, 0)!;
	 write_le_32(writer, 0)!;
	 write_le_32(writer, (uint)z.rel_offset     )!;

	 if (z.filename.len) writer.write(z.filename)!;
	 if (z.extra.len) writer.write(z.extra)!;
}

fn void? ZipWriter.write_end_record(&p, usz offset)
{
	OutStream writer = &p.writer;
	 usz size_directory = p.writer.tell() - offset;
	 write_le_32(writer, read_le_32(SIGNATURE_END[:4]))!;
	 write_le_16(writer, 0)!;
	 write_le_16(writer, 0)!;
	 write_le_16(writer, (ushort)p.entries.len())!;
	 write_le_16(writer, (ushort)p.entries.len())!;
	 write_le_32(writer, (uint)size_directory)!;
	 write_le_32(writer, (uint)offset)!;
	 write_le_16(writer, 0)!;
}

