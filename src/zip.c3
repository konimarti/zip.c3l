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
	if (!path::is_dir(base_folder)) return EXPECT_FOLDER?;

	ZipReader reader;
	reader.tparse(archive)!;

	String filename, path_str;
	Path   path;
	bool   is_directory;

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

		// Extract file
		File f = file::open(path.str_view(), "w")!;
		entry.extract_to(archive, &f)!;
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
fn void? archive(String path, OutStream output) => @pool()
{
	ZipWriter p = (ZipWriter){}.init(tmem, path, output)!;

	// Walk will write the local file headers, the (compressed) data, and
	// stores the corresponding ZipEntry record
	path::temp(path).walk(&add_to_zip, &p)!;

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

	// Get file content
	char[] content = is_dir ? {} : file::load_path(mem, path)!;

	// Prepare filename
	String filename = prepare_filename(tmem, path, w.base_path);

	// Append file to zip archive
	w.add_buffer(filename, content)!;

	return false; // Continue to the next file/directory recusrively
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
 Helper function to prepare zip-compatible filename. Called from
 `add_to_zip()`.
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
