module extra_test @test;

import std::io;
import archive::zip;

fn void test_extra_field_iterator()
{
	char[] data = {
		0x1, 0x0, 0x2, 0x0, 0xa, 0xb,  		// header 0x1, len 0x4
		0x2, 0x0, 0x4, 0x0, 0xa, 0xb, 0xc, 0xd, // header 0x2, len 0x6
	};

	ExtraFieldIterator it = { data, 0 };

	char[] first = it.next()!!;
	assert(zip::is_extra_header(first, 0x1));
	assert(first == data[:6]);

	char[] second = it.next()!!;
	assert(zip::is_extra_header(second, 0x2));
	assert(second == data[6:8]);

	if (catch err = it.next())
	{
		assert(err == io::EOF);
	}
	else
	{
		assert(false, "expected an EOF error");
	}
}

fn void test_extra_find_header()
{
	char[] data = {
		0x1, 0x0, 0x2, 0x0, 0xa, 0xb,  		// header 0x1, len 0x4
		0x2, 0x0, 0x4, 0x0, 0xa, 0xb, 0xc, 0xd, // header 0x2, len 0x6
	};


	if (try found = zip::find_extra_header(data, 0x2))
	{
		assert(found == data[6:8]);
	}
	else
	{
		assert(false, "expected error");
	}

}

fn void test_extra_field_iterator_wrong_len()
{
	char[] data = {
		0x1, 0x0, 0x66, 0x0, 0xa, 0xb,
	};

	ExtraFieldIterator it = { data, 0 };

	if (try err = it.next())
	{
		assert(false, "expected an error");
	}
}


