import archive::zip;

import std::io;

fn void main(String[] args)
{
	if (args.len < 2 || (args.len >= 2 && args[1] == "-h"))
	{
		io::printfn(`
NAME

	zipinfo -- list detailed information about a ZIP archive

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
	File f = file::open(filename, "r")!!;
	defer (void)f.close();

	ZipReader reader = zip::topen(&f)!!;
	defer reader.close();

	// Print archive info
	usz archive_len = f.seek(0, Seek.END) ?? 0;
	io::printfn("Archive: %s", filename);
	io::printfn("Zip file size: %d bytes, number of entries: %d", archive_len, reader.len());

	// Print archive entries
	double tot_comp, tot_uncomp;
	foreach (i, entry : reader)
	{
		tot_comp += entry.compress_size;
		tot_uncomp += entry.uncompress_size;
		io::printfn("%04x %d %8d %s %s %s",
			entry.rel_offset, entry.compress_method, entry.uncompress_size,
			entry.date, entry.time, entry.filename);
	}
	io::printfn("%d files, %d bytes uncompressed, %d bytes compressed: %4.1f%%",
		reader.len(), tot_uncomp, tot_comp, 100.0 * (1.0 - tot_comp / tot_uncomp));

}
