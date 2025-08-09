module archive::zip;

import std::io;
import std::collections::list;
import std::hash::crc32;

<*
 Wrapped OutStream to provide number of written bytes.
*>
struct ZipOutStream (OutStream)
{
	OutStream w;
	ulong written;
}

fn ulong ZipOutStream.tell(&self) => self.written;

fn usz? ZipOutStream.write(&self,  char[] bytes) @dynamic
{
	usz? n = self.w.write(bytes);
	if (try n) self.written += n;
	return n;
}

fn void? ZipOutStream.write_byte(&self, char c) @dynamic
{
	if (catch err = self.w.write_byte(c)) return err?;
	self.written++;
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

	 // Now we need to create the central directory.
	io::printn("writing central directory: start");
	usz offset_directory = p.writer.tell();
	foreach (entry : p.entries) entry.write_central_directory_header(writer)!;
	io::printn("writing central directory: done");

	 // And finally the End of Directory Record
	io::printn("writing end record: start");
	p.write_end_record(offset_directory)!;
	io::printn("writing end record: done");
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

<*
 Returns zip-compatible filename. Called from `zip_packer()`.
*>
fn String ZipWriter.filename(&p, Allocator allocator, Path path) @local => @pool()
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

fn void ZipWriter.free(&w)
{
	foreach (entry : w.entries) entry.free();
	w.base_path.free();
	w.entries.free();
	*w = {};
}

fn bool? zip_packer(Path path, bool is_dir, void* arg) => @pool()
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
	ZipEntry z;
	z.flag.language   = true;
	z.crc32 	  = crc32::hash(content); // crc32 should be done on the compressed data, but we do a shortcut here.
	z.compress_size   = is_dir ? 0 : content.len;
	z.uncompress_size = is_dir ? 0 : content.len;
	z.filename        = p.filename(p.allocator, path);
	z.rel_offset      = p.writer.tell(); 		// offset to begin of Local File Header

	io::printn("\n\nZipEntry created:");
	io::printn(z);

	// Write
	io::printn("writing local header: start");
	z.write_local_file_header(&p.writer)!;
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
	p.entries.push(z);

	// Continue to the next file/directory recusrively
	return false;
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

fn void? ZipWriter.write_end_record(&p, usz offset)
{
	OutStream writer = &p.writer;
	 usz size_directory = p.writer.tell() - offset;
	 write_le_32(writer, read_le_32(SIGNATURE_END[:4]))!;
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, 0                )!;
	 write_le_16(writer, (ushort)p.entries.len()      )!;
	 write_le_16(writer, (ushort)p.entries.len()      )!;
	 write_le_32(writer, (uint)size_directory   )!;
	 write_le_32(writer, (uint)offset           )!;
	 write_le_16(writer, 0                )!;
}
