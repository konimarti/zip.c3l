<*
 This module provides archiving functionality for the ZIP/ZIP64 format [1].

 [1] https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
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

faultdef CORRUPT_FILE,
	 EXPECT_FOLDER,
	 DATA_DESCRIPTOR_MISMATCH,
	 INVALID_END_RECORD,
	 INVALID_CENTRAL_FILE_HEADER,
	 INVALID_LOCAL_FILE_HEADER,
	 INVALID_DATA_DESCRIPTOR,
	 INVALID_CRC32_HASH,
	 MISSING_ZIP64_EXTRA,
	 MISSING_ZIP64_LOCATOR,
	 SIGNATURE_MISMATCH,
	 UNSUPPORTED_COMPRESSION,
	 UNSUPPORTED_ZIP64;

const ZipVersion VERSION_USED = { .spec = 20, .compat = Compat.UNIX };
const ZipVersion MIN_VERSION  = { .spec = 20, .compat = 0 };

<*
 Open a zip archive from a stream. The `archive` stream needs to be closed by
 the caller.
*>
fn ZipReader? open(Allocator allocator, InStream archive)
{
	ZipReader reader;
	reader.init(allocator).parse(archive)!;
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
	reader.tinit().parse(archive)!;

	String filename, path_str;
	Path   path;
	bool   is_directory, checksum;

	foreach (entry: reader)
	{
		filename = entry.filename;
		is_directory = filename.ends_with("/");

		// Normalize path from UNIX sep to whatever is used.
		path_str = path::normalize(filename, PathEnv.POSIX)!;
		path = base_folder.tappend(path_str)!;

		// Build directory structure and extract file.
		String verb, err;
		if (is_directory)
		{
			path::mkdir(path, true)!;
			verb = "creating";
		}
		else
		{
			path::mkdir(path.dirname(), true)!;
			File f = file::open(path.str_view(), "w")!;
			defer (void)f.close();
			ExtractResult result = entry.extract_to(&f, archive)!;
			verb = entry.compress_method == COMPRESS_STORE ?
				"extracting" : "inflating";
			if (result.verify_crc && !result.crc_match())
			{
				err = string::tformat("bad crc %f (should be %f)",
					result.crc_calculated, result.crc_reported);
			}
		}

		io::eprintfn("%11s:  %s %s", verb, filename, err);
	}
}

<*
 Create a zip archive. Returns an empty ZipWriter. Add files to the it.  Close
 the ZipWriter to write the central directory and end record.
*>
fn ZipWriter? create(Allocator allocator, OutStream output) => @pool()
{
	ZipWriter writer;
	writer.init(allocator, output)!;
	return writer;
}
fn ZipWriter? tcreate(OutStream output) @inline => create(tmem, output);

<*
 Create a new zip archive and write it to `output`. The zip archive contains the
 file or folder in `path`. The filenames are stripped with the path prefix
 defined in `ref_path`.
 @param path            : "File or folder to archive into output."
 @param ref_path        : "Defines a path prefix to be stripped from the filenames."
 @param [&inout] output : "Destination output for newly created zip archive."
*>
fn void? archive(Path path, Path ref_path, OutStream output) => @pool()
{
	ZipWriter writer;
	writer.init(tmem, output)!;

	// Add (empty) base directory
	if (path::is_dir(path))
	{
		String name = strip_base(tmem, path, ref_path);
		name = format_filename(tmem, name, true);
		writer.write_buffer(name, {})!;
	}

	ZipDirectoryWalker walker;
	walker.init(&writer, ref_path);

	// Walk will write the local file headers, the (compressed) data, and
	// stores the corresponding ZipEntry record
	path.walk(&add_to_zip, &walker)!;

	// Close ZipWriter will write central directory and the end record.
	writer.close()!;
}

struct ZipDirectoryWalker
{
	ZipWriter *writer;
	Path      base_path;
	bool      verbose;
}

fn void ZipDirectoryWalker.init(&self, ZipWriter *w, Path start_dir, bool verbose = true)
{
	*self = { .writer = w, .base_path = start_dir, .verbose = verbose };
}

<*
 Helper function for the walking the directory tree in `zip::archive()`.
 It is called for every file or directory that is encountered.
*>
fn bool? add_to_zip(Path current_path, bool is_dir, void* arg) @private => @pool()
{
	if (!arg) return true; // Stop directory walk

	// Cast directory walker.
	ZipDirectoryWalker *walker = (ZipDirectoryWalker*)arg;

	// Get file content.
	char[] content;
	if (!is_dir) content = file::load_path(mem, current_path)!;

	// Strip base_path from current file path.
	String filename = strip_base(tmem, current_path, walker.base_path);

	// Format filename.
	filename = format_filename(tmem, filename, is_dir);

	// Append file to zip archive
	ZipCompressMethod method = content.len < 32  || content.len > 1e9 ? COMPRESS_STORE : COMPRESS_DEFLATE;
	ZipEntry entry = walker.writer.write_buffer(filename, content, method)!;

	double ratio = entry.uncompress_size > 0 ?
		100.0 * (1.0 - (double)entry.compress_size / entry.uncompress_size) : 0.0;

	String comp_info;
	switch (method)
	{
		case COMPRESS_STORE:
			comp_info = string::tformat(" (stored %.0f%%)", ratio);
		case COMPRESS_DEFLATE:
			comp_info = string::tformat(" (deflated %.0f%%)", ratio);
		default:
			comp_info = "";
	}

	if (walker.verbose)
	{
		io::printfn("  adding: %s%s", filename, comp_info);
	}

	if (content.ptr) allocator::free(mem, content.ptr);

	return false; // Continue to the next file/directory recursively
}

fn String strip_base(Allocator allocator, Path file_path, Path base) @inline
{
	return file_path.str_view().strip(base.str_view()).copy(allocator);
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
