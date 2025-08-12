import archive::zip;
import std::io;

// E.g. zipex resources/test.zip /tmp/
fn int usage(String app)
{
	io::printfn(`
	Usage: %s <archive> <path>

	<archive> : name of the ZIP archive
	<path>    : extract files to this folder

	`, app);
	return 1;
}

fn int main(String[] args) => @pool()
{
	if (args.len < 3) return usage(args[0]);

	File archive = file::open(args[1], "r")!!;
	defer (void)archive.close();

	zip::extract(&archive, args[2])!!;

	return 0;
}
