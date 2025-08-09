import archive::zip;

import std::io;

fn void main(String[] args) => @pool()
{
	File output = file::open("/tmp/test.zip", "w")!!;
	defer (void)output.close();

	zip::write("resources/test_zip", &output)!!;
}
