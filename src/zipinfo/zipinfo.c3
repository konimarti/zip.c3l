import archive::zip;

import std::io;

fn void main(String[] args)
{
	if (args.len < 2 || (args.len >= 2 && args[1] == "-h"))
	{
		io::printfn(`
NAME

	zipinfo - list detailed information about a ZIP archive

SYNOPSIS

	zipinfo file [file(s) ..]

ARGUMENTS

	file	Path of the ZIP archive(s).

OUTPUT
	Lists the technical information of a ZIP archive in tabular form.

	The first field shows the offset in bytes to the local file header.
	The second and third field contain the compression method (store=0,
	deflate=8) and the uncompressed file size.
	The next two fields are the date and time of the last modification and
	the last field is the filename.
	`);
		return;
	}

	foreach (arg : args[1 ..]) show_zip_info(arg);
}

fn void show_zip_info(String filename) => @pool()
{
	File f = file::open(filename, "rb+")!!;
	defer (void)f.close();

	ZipReader reader = zip::topen(&f)!!;
	defer reader.free();

	// Print archive info.
	usz archive_len = f.seek(0, Seek.END) ?? 0;
	io::printfn("Archive: %s", filename);
	io::printfn("Zip file size: %d bytes, number of entries: %d", archive_len, reader.len());
	io::printf("%s", reader);
}
