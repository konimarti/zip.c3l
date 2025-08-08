import archive::zip;

import std::io;

fn void main(String[] args) => @pool()
{
	File target = file::open("/tmp/test.zip", "w")!!;
	defer (void)target.close();

	Path base = path::temp("resources/test_zip")!!;
	zip::tpack(base, &target)!!;
}
