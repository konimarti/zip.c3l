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

	ZipCentralFileHeader cf;
	ZipLocalFileHeader lf;

	io::printfn("%-40s %-12s %-12s %-16s %-12s)", "Filename", "Size (comp.)", "Size", "CRC32", "Compression");
	foreach (zip_file : z)
	{
		zip_file.unpack(&cf, &lf);
		io::printfn("%-40s %-12d %-12d %-16d %-12d",
			lf.filename, lf.compress_size, lf.uncompress_size, lf.crc32, cf.compress_method);
	}
}
