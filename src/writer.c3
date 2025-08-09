module archive::zip;

import std::io;
import std::collections::list;
import std::hash::crc32;

<*
 Pack a file or folder into a zip archive.
*>
fn void? pack(Allocator allocator, Path base, File* writer)
{
	ZipWriter p = (ZipWriter){}.init(allocator, base, writer);

	// Walk will write the local file headers, the (compressed) data, and
	// stores the corresponding ZipFile record
	 base.walk(&packer, &p)!;

	 // Now we need to create the central directory.
	io::printn("writing central directory: start");
	usz offset_directory = writer.seek(0, Seek.CURSOR)!;
	foreach (z : p.files) z.write_central_directory_header(writer)!;
	io::printn("writing central directory: done");

	 // And finally the End of Directory Record
	io::printn("writing end record: start");
	p.write_end_record(writer, offset_directory)!;
	io::printn("writing end record: done");
}
fn void? tpack(Path base, File* writer) => pack(tmem, base, writer);

alias ZipFileList = List { ZipFile };

struct ZipWriter
{
	Path        base_path;
	File*       writer;
	ZipFileList files;
	Allocator   allocator;
}

fn ZipWriter ZipWriter.init(&p, Allocator allocator, Path base, File* writer)
{
	p.allocator = allocator;
	p.base_path = base;
	p.writer    = writer;

	p.files.init(allocator);

	return *p;
}

<*
 Returns zip-compatible filename.
*>
fn String ZipWriter.filename(&p, Allocator allocator, Path path) => @pool()
{
	String base = p.base_path.absolute(tmem)!!.str_view();
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
	if (path::is_dir(p.base_path))
	{
		String top = p.base_path.basename().trim("/");
		tmp.append_chars(top);
		tmp.append_char('/');
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

fn void ZipWriter.free(&p)
{
	foreach (f : p.files) f.free();
	p.files.free();
}

fn bool? packer(Path path, bool is_dir, void* arg) => @pool()
{
	defer catch io::printn("leaving packer");
	io::printfn("entering packer for file: %s", path.str_view());

	if (!arg) return true; // Stop directory walk

	ZipWriter *p = (ZipWriter*)arg;

	// Get file content
	io::printn("before load");
	char[] content = is_dir ? {} : file::load_path(mem, path)!;
	io::printn("after load");

	// Hack an uncompressed zip file together
	ZipFile z;
	z.flag.language   = true;
	z.crc32 	  = crc32::hash(content); // crc32 should be done on the compressed data, but we do a shortcut here.
	z.compress_size   = is_dir ? 0 : content.len;
	z.uncompress_size = is_dir ? 0 : content.len;
	z.filename        = p.filename(p.allocator, path);
	z.rel_offset      = p.writer.seek(0, Seek.CURSOR)!; 		// offset to begin of Local File Header

	io::printn("\n\nZipFile created:");
	io::printn(z);

	// Write
	io::printn("writing local header: start");
	z.write_local_file_header(p.writer)!;
	io::printn("writing local header: done");

	// Only write content if it is not a directory and if there is data.
	if (!is_dir || content.len > 0)
	{
		io::printn("writing data: start");
		p.writer.write(content)!; // TODO: should be the compressed data
		io::printn("writing data: done");
	}

	// Release content mem
	if (!is_dir) allocator::free(mem, content.ptr);

	// Store ZipEntry since We need it for the central directory
	p.files.push(z);

	// Continue to the next file/directory recusrively
	return false;
}

fn void? ZipFile.write_local_file_header(&z, File* writer)
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

fn void? ZipFile.write_central_directory_header(&z, File* writer)
{
	 write_le_32(writer, read_le_32(SIGNATURE_CENTRAL[:4]))!;
	 write_le_16(writer, (ushort)z.version_used    )!;
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
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, 0                )!;
	 write_le_32(writer, 0                )!;
	 write_le_32(writer, (uint)z.rel_offset     )!;

	 if (z.filename.len) writer.write(z.filename)!;
	 if (z.extra.len) writer.write(z.extra)!;
}

fn void? ZipWriter.write_end_record(&p, File* writer, usz offset)
{
	 usz size_directory = writer.seek(0, Seek.CURSOR)! - offset;
	 write_le_32(writer, read_le_32(SIGNATURE_END[:4]))!;
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, (ushort)p.files.len()      )!;
	 write_le_16(writer, (ushort)p.files.len()      )!;
	 write_le_32(writer, (uint)size_directory   )!;
	 write_le_32(writer, (uint)offset           )!;
	 write_le_16(writer, 0                )!;
}

<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_16(stream, ushort s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
}
<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_32(stream, uint s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
	stream.write_byte((char)(s >> 16))!;
	stream.write_byte((char)(s >> 24))!;
}

<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_64(stream, ulong s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
	stream.write_byte((char)(s >> 16))!;
	stream.write_byte((char)(s >> 24))!;
	stream.write_byte((char)(s >> 32))!;
	stream.write_byte((char)(s >> 40))!;
	stream.write_byte((char)(s >> 48))!;
	stream.write_byte((char)(s >> 56))!;
	stream.write_byte((char)(s >> 56))!;
}
