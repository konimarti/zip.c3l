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

	ZipMeta z = zip::tread(&f)!!;

	// Print file info (filename, compressed and uncompressed sizes, compression)
	io::printfn("%-40s %-12s %-12s %-12s", "Filename", "Comp. Size", "Size", "Compression");
	foreach (zip_file : z) io::print(zip_file);

	// Print content of files.
	foreach (zip_file : z)
	{
		io::printfn("\n*** filename : %s", zip_file.filename);
		io::printfn("    date time: %s %s", zip_file.date, zip_file.time);
		io::printn("+++");
		zip_file.write_to(io::stdout(), &f)!!;
		io::printn("---");
	}

	// archive::zip::ls
	PathList list = zip::ls(mem, &f)!!;
	io::printn(list);

	// archive::zip::extract
	// Path folder = path::temp("/tmp/")!!;
	Path folder = path::temp("/home/km/test/")!!;
	zip::extract(folder, &f)!!;
}
