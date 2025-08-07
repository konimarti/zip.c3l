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

	ZipMeta z;
	z.parse(&f, tmem)!!;

	// Print file info (filename, compressed and uncompressed sizes, compression)
	io::printfn("%-40s %-12s %-12s %-12s", "Filename", "Comp. Size", "Size", "Compression");
	foreach (zip_file : z) io::print(zip_file);

	// Print content of files.
	foreach (zip_file : z)
	{
		io::printfn("\n*** filename: %s", zip_file.filename()!!);
		// zip_file.copy_to(&f, io::stdout())!!;
	}

	// archive::zip::ls
	PathList list = zip::ls(mem, &f)!!;
	io::printn(list);

	// archive::zip::extract
	Path folder = path::temp("/tmp/")!!;
	zip::extract(&f, folder)!!;
}
