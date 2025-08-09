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

	io::printfn("\n=== zip archive: %s", filename);

	ZipReader z = zip::topen(&f)!!;
	defer z.close();

	// Print file info (filename, compressed and uncompressed sizes, compression)
	io::printfn("%-40s %-12s %-12s %-12s", "Filename", "Comp. Size", "Size", "Compression");
	foreach (entry : z) io::print(entry);

	// Print content of files.
	foreach (entry : z)
	{
		io::printfn("\n*** filename : %s", entry.filename);
		io::printfn("    date time: %s %s", entry.date, entry.time);
		io::printn("+++");
		entry.extract_to(io::stdout(), &f)!!;
		io::printn("---");
	}

	// archive::zip::ls
	PathList list = zip::ls(mem, &f)!!;
	io::printn(list);

	// archive::zip::extract
	// Path folder = path::temp("/tmp/")!!;
	// Path folder = path::temp("/home/km/test/")!!;
	// zip::extract(folder, &f)!!;
}
