import archive::zip;

import std::io;

fn void main(String[] args)
{
	if (args.len <= 1)
	{
		io::printn(`
			Usage: zipinfo [file.zip] [file2.zip] ..
		`);
		return;
	}

	foreach (arg : args[1 ..]) show_zip_info(arg);
}

fn void show_zip_info(String filename) => @pool()
{
	File f = file::open(filename, "r")!!;
	defer (void)f.close();

	Zip z;
	z.parse(&f, tmem)!!;

	// Print file info.
	io::printfn("%-40s %-12s %-12s %-16s %-12s", "Filename", "Comp. Size", "Size", "CRC32", "Compression");
	foreach (zip_file : z)
	{
		io::printfn("%-40s %-12d %-12d %-16d %-12d",
			zip_file.filename(), zip_file.compressed_size(), zip_file.uncompressed_size(),
			zip_file.crc32(), zip_file.compression_method());
	}

	// Print content of files.
	foreach (zip_file : z)
	{
		io::printfn("\n*** filename: %s", zip_file.filename());
		zip_file.copy_to(&f, io::stdout())!!;
	}
}
