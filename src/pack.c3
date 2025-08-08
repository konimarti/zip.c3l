module archive::zip;

import std::io;
import std::collections::list;
import std::hash::crc32;

<*
 Pack a file or folder into a zip archive.
*>
fn void? pack(Allocator allocator, Path base, File* writer)
{
	Packer p = (Packer){}.init(allocator, base, writer);

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

struct Packer
{
	Path        base;
	String      prefix;
	File*   writer;
	ZipFileList files;
	Allocator   allocator;
}

fn Packer Packer.init(&p, Allocator allocator, Path base, File* writer)
{
	p.allocator = allocator;
	p.base   = base;
	p.writer = writer;
	p.files.init(allocator);
	return *p;
}

<*
 Returns zip-compatible filename.
*>
fn String Packer.filename(&p, Allocator allocator, Path path) => @pool()
{
	String base = p.base.absolute(tmem)!!.str_view();
	String name = path.str_view().strip(base).tcopy();

	foreach (&c : name)
	{
		if (path::is_win32_separator(*c))
		{
			*c = path::PREFERRED_SEPARATOR_POSIX;
		}
	}

	DString tmp = dstring::temp("");

	if (path::is_dir(p.base))
	{
		String top = p.base.basename().trim("/");
		tmp.append_chars(top);
		tmp.append_char('/');
	}

	tmp.append_chars(name.trim_left("/"));

	if (path::is_dir(path) && !tmp.str_view().ends_with("/"))
	{
		tmp.append_char('/');
	}

	return tmp.copy_str(allocator);
}

fn void Packer.free(&p)
{
	foreach (f : p.files) f.free();
	p.files.free();
}

fn bool? packer(Path path, bool is_dir, void* arg) => @pool()
{
	defer catch io::printn("leaving packer");
	io::printfn("entering packer for file: %s", path.str_view());

	Packer *p = (Packer*)arg;

	// Get data
	io::printn("before load");
	char[] data = is_dir ? {} : file::load_path(mem, path)!;
	io::printn("after load");

	// Hack an uncompressed zip file together
	ZipFile z;
	z.flag.language   = true;
	z.crc32 	  = crc32::hash(data); // crc32 should be done on the compressed data, but we do a shortcut here.
	z.compress_size   = is_dir ? 0 : data.len;
	z.uncompress_size = is_dir ? 0 : data.len;
	z.filename        = p.filename(p.allocator, path);
	z.rel_offset      = p.writer.seek(0, Seek.CURSOR)!; 		// offset to begin of Local File Header

	io::printn("\n\nZipFile created:");
	io::printn(z);

	// Write
	io::printn("writing local header: start");
	z.write_local_file_header(p.writer)!;
	io::printn("writing local header: done");


	if (!is_dir)
	{
		io::printn("writing data: start");
		p.writer.write(data)!; // TODO: should be the compressed data
		io::printn("writing data: done");
	}

	allocator::free(mem, data.ptr);

	p.files.push(z); // We need it for the central directory

	return false; // return true when we want to stop
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

fn void? Packer.write_end_record(&p, File* writer, usz offset)
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
