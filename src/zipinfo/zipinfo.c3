import zip;

import tinf::inflate;

import std::io;

fn void main(String[] args)
{
	foreach (arg : args[1 ..]) show_zip_info(arg);
}

fn void show_zip_info(String filename) => @pool()
{
	File f = file::open(filename, "r")!!;
	defer (void)f.close();

	// Find record
	usz loc = zip::find_eocd_record(&f)!!;

	io::printfn("location found: %d", loc);

	// Set file to the start of the eocd record
	f.seek(loc, Seek.SET)!!;

	// Parse end of directory record
	ZipEOCD end_record = zip::parse_eocd(&f, tmem)!!;

	io::printfn("Zipinfo for %s", filename);
	io::printn( "-------------------------");
	io::printn(end_record);

	ZipCDFH[] headers = mem::talloc_array(ZipCDFH, end_record.tot_nr_records);

	f.seek(end_record.rel_offset, Seek.SET)!!;
	foreach (i, &header : headers)
	{
		*header = zip::parse_cdfh(&f)!!;
		io::printfn(" ** Header %d **", i);
		io::printn(*header);
	}

	ZipLFH[] file_headers = mem::talloc_array(ZipLFH, headers.len);
	foreach (i, &file_header : file_headers)
	{
		f.seek(headers[i].rel_offset, Seek.SET)!!;
		*file_header = zip::parse_lfh(&f)!!;
		io::printfn(" ** File Header %d **", i);
		io::printn(*file_header);

		if (i != 9) continue;

		// print file 9
		char[] compressed = mem::talloc_array(char, file_header.compress_size);
		f.read(compressed[..])!!;

		// char[] uncompressed = mem::talloc_array(char, file_header.uncompress_size);
                //
		// inflate::uncompress(uncompressed, compressed)!!;
                //
		// file::save("raylib.lib", uncompressed)!!;
	}

}
