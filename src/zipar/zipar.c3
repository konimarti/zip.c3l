import archive::zip;
import std::io;

// E.g. zipar /tmp/test.zip resources/test_zip
fn int usage()
{
	io::printn(`

	zipar -- create ZIP archive

	Usage: zipar archive path

	archive : name of the ZIP archive to create
	path    : path to a file or directory to be archived

	`);
	return 1;
}

fn int main(String[] args) => @pool()
{
	if (args.len < 3) return usage();

	File output = file::open(args[1], "wb+")!!;
	defer (void)output.close();

	zip::archive(args[2], &output)!!;

	return 0;
}
