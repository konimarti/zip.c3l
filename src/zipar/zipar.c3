import archive::zip;
import std::io;

// E.g. zipar /tmp/test.zip resources/test_zip
fn int usage(String app)
{
	io::printfn(`
	Usage: %s <archive> <path>

	<archive> : name of the ZIP archive
	<path>    : path to a file or directory to be archived

	`, app);
	return 1;
}

fn int main(String[] args) => @pool()
{
	if (args.len < 3) return usage(args[0]);

	File output = file::open(args[1], "w")!!;
	defer (void)output.close();

	zip::archive(args[2], &output)!!;

	return 0;
}
