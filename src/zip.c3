<*
 This module makes it easy to read and write files in the ZIP/ZIP64 format [1]
 natively in C3, with a simple interface. It's especially useful for C3
 projects that need basic ZIP archiving functionality without relying on
 external dependencies or heavy native bindings.

 WinZip-based AE-x encryption [2] will be implemented later.

 [1] https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
 [2] https://www.winzip.com/en/support/aes-encryption/

*>
module archive::zip;

import std::io;
import std::collections::list;

// Compression methods
alias ZipCompressMethod = ushort;
const ZipCompressMethod COMPRESS_STORE   = 0;
const ZipCompressMethod COMPRESS_DEFLATE = 8;
const ZipCompressMethod COMPRESS_BZIP2   = 12; // TODO: unsupported
const ZipCompressMethod COMPRESS_ZSTD    = 93; // TODO: unsupported
const ZipCompressMethod COMPRESS_MP3     = 94; // TODO: unsupported
const ZipCompressMethod COMPRESS_XZ      = 95; // TODO: unsupported
const ZipCompressMethod COMPRESS_JPEG    = 96; // TODO: unsupported
const ZipCompressMethod COMPRESS_AEX     = 99; // TODO: unsupported

// Signatures
alias ZipSignature = char[4];
const ZipSignature SIGNATURE_CENTRAL       = {0x50, 0x4b, 0x01, 0x02};
const ZipSignature SIGNATURE_LOCAL         = {0x50, 0x4b, 0x03, 0x04};
const ZipSignature SIGNATURE_END           = {0x50, 0x4b, 0x05, 0x06};
const ZipSignature SIGNATURE_END_ZIP64     = {0x50, 0x4b, 0x06, 0x06};
const ZipSignature SIGNATURE_LOCATOR_ZIP64 = {0x50, 0x4b, 0x06, 0x07};
const ZipSignature SIGNATURE_DATA          = {0x50, 0x4b, 0x07, 0x08}; // optional
const ZipSignature SIGNATURE_DIGITAL_SIG   = {0x50, 0x4b, 0x05, 0x05};

faultdef NOT_FOUND,
	EXPECT_FOLDER,
	INVALID_END_RECORD,
	INVALID_CENTRAL_FILE_HEADER,
	INVALID_LOCAL_FILE_HEADER,
	INVALID_DATA_DESCRIPTOR,
	INVALID_CRC32_HASH,
	SIGNATURE_MISMATCH,
	UNSUPPORTED_COMPRESSION_METHOD,
	UNSUPPORTED_ZIP64;

<*
 Open a zip archive from a stream. The `archive` stream needs to be closed by
 the caller.
*>
fn ZipReader? open(Allocator allocator, InStream archive)
{
	ZipReader reader;
	reader.parse(allocator, archive)!;
	return reader;
}
fn ZipReader? topen(InStream archive) @inline => open(tmem, archive);

<*
 Extract the zip archive to a folder.
*>
fn void? extract(InStream archive, String folder) => @pool()
{
	Path base_folder = path::temp(folder)!;
	if (!path::is_dir(base_folder)) return EXPECT_FOLDER~;

	ZipReader reader;
	reader.tparse(archive)!;

	String filename, path_str;
	Path   path;
	bool   is_directory, checksum;

	foreach (entry : reader)
	{
		filename = entry.filename;
		is_directory = filename.ends_with("/");

		// Normalize path from UNIX sep to whatever is used
		path_str = path::normalize(filename, PathEnv.POSIX)!;
		path = base_folder.tappend(path_str)!;

		// Build directory structure
		if (is_directory)
		{
			path::mkdir(path, true)!;
			continue;
		}
		path::mkdir(path.dirname(), true)!;

		io::printfn("Extracting %s to %s", filename, path);

		// Extract file
		File f = file::open(path.str_view(), "w")!;
		entry.extract_to(archive, &f, &checksum)!;
		if (!checksum) io::eprintfn("File with incorrect CRC32 checksum: %s", filename);
		f.close()!;
	}
}
<*
 List the filenames in a zip archive.
*>
fn PathList? ls(Allocator allocator, InStream archive) => @pool()
{
	ZipReader reader;
	reader.tparse(archive)!;

	PathList list;
	list.init(allocator);
	defer catch list.free();

	foreach (entry : reader)
	{
		String path_str = path::normalize(entry.filename, PathEnv.POSIX)!;
		Path path = path::new(allocator, path_str)!!;
		list.push(path);
	}
	return list;
}
fn PathList? tls(InStream archive) @inline => ls(tmem, archive);

<*
 Create a zip archive. Returns an empty ZipWriter. Add files to the it.  Close
 the ZipWriter to write the central directory and end record.
*>
fn ZipWriter? create(Allocator allocator, OutStream output) => @pool()
{
	return (ZipWriter){}.init(allocator, {}, output);
}
fn ZipWriter? tcreate(OutStream output) @inline => create(tmem, output);

<*
 Archive a file or folder into a zip archive and write it to output.
*>
fn void? archive(String base_dir, OutStream output) => @pool()
{
	ZipWriter p = (ZipWriter){}.init(tmem, base_dir, output)!;

	Path path = path::temp(base_dir)!;

	// Add (empty) base directory
	if (path::is_dir(path))
	{
		String s = format_filename(tmem, path.basename(), true);
		p.add_buffer(s, {})!;
	}

	// Walk will write the local file headers, the (compressed) data, and
	// stores the corresponding ZipEntry record
	path.walk(&add_to_zip, &p)!;

	// Close ZipWriter will write central directory and the end record.
	p.close()!;
}

<*
 Helper function for the walking the directory tree in `zip::archive()`.
 It is called for every file or directory that is encountered.
*>
fn bool? add_to_zip(Path path, bool is_dir, void* arg) @private => @pool()
{
	if (!arg) return true; // Stop directory walk
	ZipWriter *w = (ZipWriter*)arg;
	String filename;
	char[] content;

	// Get file content
	content = is_dir ? {} : file::load_path(mem, path)!;

	// Strip base_path from current file path
	filename = strip_base(tmem, path, w.base_path);

	// Format filename
	filename = format_filename(tmem, filename, is_dir);

	// Append file to zip archive
	w.add_buffer(filename, content)!;

	// Release content mem
	allocator::free(mem, content.ptr);

	return false; // Continue to the next file/directory recursively
}

fn String strip_base(Allocator allocator, Path file_path, Path base) => @pool()
{
	String parent;
	if (try abs_base = base.absolute(tmem))
	{
		parent = (abs_base.parent() ?? abs_base).str_view();
	}
	else
	{
		parent = base.str_view();
	}
	return file_path.str_view().strip(parent).copy(allocator);
}

fn void test_zip_writer_filename() @test => @pool()
{
	String got;

	got = format_filename(tmem, "foo/bar", false);
	assert(got == "foo/bar", "got: %s", got);

	got = format_filename(tmem, "/foo/bar", false);
	assert(got == "foo/bar", "got: %s", got);

	got = format_filename(tmem, "foo/bar", true);
	assert(got == "foo/bar/", "got: %s", got);

	got = format_filename(tmem, "foo/bar/", true);
	assert(got == "foo/bar/", "got: %s", got);

	got = format_filename(tmem, "foo", false);
	assert(got == "foo", "got: %s", got);

	got = format_filename(tmem, "foo", true);
	assert(got == "foo/", "got: %s", got);
}

<*
 Helper function to prepare zip-compatible filename. Called from
 `add_to_zip()`.

 4.4.17 file name: (Variable)

       4.4.17.1 The name of the file, with optional relative path.
       The path stored MUST NOT contain a drive or
       device letter, or a leading slash.  All slashes
       MUST be forward slashes '/' as opposed to
       backwards slashes '\' for compatibility with Amiga
       and UNIX file systems etc.  If input came from standard
       input, there is no file name field.

*>
fn String format_filename(Allocator allocator, String rel_path, bool is_dir) @local => @pool()
{
	DString name = dstring::temp();

	// Convert Win32 paths to forward slash path according to zip spec.
	foreach (c : rel_path)
	{
		if (path::is_win32_separator(c))
		{
			c = path::PREFERRED_SEPARATOR_POSIX;
		}
		name.append_char(c);
	}

	// Append separator if rel_path is a directory
	if (is_dir && name[name.len()-1] != '/')
	{
		name.append_char('/');
	}

	// Remove leading path separator
	return name.str_view().trim_left("/").copy(allocator);
}
