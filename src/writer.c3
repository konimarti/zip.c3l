module archive::zip;

import std::io, std::time;
import std::collections::list;
import std::hash::crc32;

<*
 Create a zip archive. Returns an empty zip writer. Add files to the it.
 Close the ZipWrier to write the central directory and end record.
*>
fn ZipWriter? create(Allocator allocator, OutStream writer) => @pool()
{
	return (ZipWriter){}.init(allocator, {}, writer);
}

<*
 Write a file or folder into a zip archive.
*>
fn void? write(String path, OutStream writer) => @pool()
{
	ZipWriter p = (ZipWriter){}.init(tmem, path, writer)!;

	// Walk will write the local file headers, the (compressed) data, and
	// stores the corresponding ZipEntry record
	path::temp(path).walk(&zip_packer, &p)!;

	// Close ZipWriter will write central directory and the end record.
	p.close()!;
}

fn bool? zip_packer(Path path, bool is_dir, void* arg) => @pool()
{
	if (!arg) return true; // Stop directory walk
	ZipWriter *p = (ZipWriter*)arg;

	// Get file content
	char[] content = is_dir ? {} : file::load_path(mem, path)!;

	// Prepare filename
	String filename = prepare_filename(tmem, path, w.base_path);

	// Append file to zip archive
	w.add_buffer(filename, content)!;

	return false; // Continue to the next file/directory recusrively
}

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

<*
 Add content to the zip file.

 The caller of this function should ensure that the filename follows the zip
 specification (no leading slash and trailing slash for directories).
*>
fn void? ZipWriter.add_buffer(&w, String filename, char[] content)
{
	// Hack an uncompressed zip file together
	ZipEntry entry;
	entry.version_min     = 0; // TODO
	entry.flag.language   = true;
	entry.compress_method = 0; // TODO
	entry.crc32 	      = crc32::hash(content); // crc32 should be done on the compressed data, but we do a shortcut here.
	entry.compress_size   = content.len;
	entry.uncompress_size = content.len;
	entry.filename        = filename.copy(w.allocator);
	// z.extra		  = null; // TODO
	entry.rel_offset      = w.writer.tell(); 	  // offset to begin of Local File Header

	entry.version_used    = 0; // TODO
	entry.internal_attr   = 0; // TODO
	entry.external_attr   = 0; // TODO

	DateTime time_now = datetime::now().to_local();
	entry.date.year    = (char)(time_now.year - 1980);
	entry.date.month   = time_now.month.ordinal + 1;
	entry.date.day     = time_now.day;
	entry.time.hours   = time_now.hour;
	entry.time.minutes = time_now.min;
	entry.time.halfsec = time_now.sec / 2;

	// Write
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

fn void test_zip_writer_filename() @test => @pool()
{
	String got;

	got = prepare_filename(tmem,
		path::temp("/tmp/foo"), path::temp("/tmp"))!!;
	assert(got == "tmp/foo", "got: %s", got);

	got = prepare_filename(tmem,
		path::temp("tmp/bar"), path::temp("tmp"))!!;
	assert(got == "tmp/bar", "got: %s", got);

	got = prepare_filename(tmem,
		path::temp("tmp\\foo\\bar"), path::temp("tmp"))!!;
	assert(got == "tmp/foo/bar", "got: %s", got);

	got = prepare_filename(tmem,
		path::temp("tmp\\foo\\bar"), path::temp("/"))!!;
	assert(got == "tmp/foo/bar", "got: %s", got);
}

<*
 Returns zip-compatible filename. Called from `zip_packer()`.
*>
fn String prepare_filename(Allocator allocator, Path path, Path base_path) @local => @pool()
{
	String base = base_path.absolute(tmem)!!.str_view();
	String name = path.str_view().strip(base).tcopy();
	DString tmp = dstring::temp("");

	// Convert Win32 paths to forward slash path according to zip spec.
	foreach (&c : name)
	{
		// TODO: Do we need to handle escaped separators?
		if (path::is_win32_separator(*c))
		{
			*c = path::PREFERRED_SEPARATOR_POSIX;
		}
	}

	// Append prefix path
	if (path::is_dir(base_path))
	{
		String top = base_path.basename().trim("/");
		tmp.append_chars(top);
		if (top.len) tmp.append_char('/');
	}

	// Append filename path (rebased from base_path)
	tmp.append_chars(name.trim_left("/"));

	// Append path separator if directory
	if (path::is_dir(path) && !tmp.str_view().ends_with("/"))
	{
		tmp.append_char('/');
	}

	return tmp.copy_str(allocator);
}
