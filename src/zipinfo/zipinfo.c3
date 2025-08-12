import archive::zip;

import std::io;

fn void main(String[] args)
{
	if (args.len < 2)
	{
		io::printfn(`
			Usage: %s <file.zip> [<file2.zip> ..]
		`, args.len >= 1 ? args[0] : "zipinfo");
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
	io::printfn("Archive: %s", filename);
	io::printfn("Total entries: %d", reader.len());

	// Print archive entries
	foreach (i, entry : reader)
	{
		io::printfn("Entry %d:", i);
		io::printfn("  Name: %s", entry.filename);
		io::printfn("  Uncompressed size: %d", entry.uncompress_size);
		io::printfn("  Compressed size: %d", entry.compress_size);
		io::printfn("  Compression: %s", entry.compress_method);
		if (entry.compress_size > 0) io::printfn("  Compression Ratio: %.2f%%", (100.0 * entry.compress_size) / entry.compress_size);
		io::printfn("  Timestamp: %s %s", entry.date, entry.time);
		io::printfn("  Offset: %d", entry.rel_offset);
		io::printfn("  Flags: 0x%04X", (ushort)entry.flag);
	}
}
