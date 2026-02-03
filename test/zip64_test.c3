<*
 Tests for archive::zip module (ZIP64 format).
*>
module archive::zip64_test;
import std::io, archive::zip;

// The following byte chunks represent a ZIP archive in the ZIP64 format. The
// ZIP archive contains one file ("HELLO") with the content ("HELLO WORLD").

// Zip64 format: EOCD record with central directory offset set to 0xFF_FF_FF_FF.
char[*] zip64_eocd = x`504b0304000000000000000000005b86e5870b0000000b00000005000000
48454c4c4f48454c4c4f20574f524c44504b010200000000000000000000
0000000000000b0000000b00000005000000000000000000000000000000
000048454c4c4f504b06062c000000000000000000000000000000000000
000100000000000000010000000000000033000000000000002e00000000
000000504b060700000000610000000000000000000000504b0506000000
000100010033000000ffffffff0000`;

// Zip64 format: EOCD record and CDFH offset set to 0xFF_FF_FF_FF. CDFH with
// Zip64 extra block.
char[*] zip64_cdfh = x`504b0304000000000000000000005b86e5870b0000000b00000005000000
48454c4c4f48454c4c4f20574f524c44504b010200000000000000000000
0000000000000b0000000b00000005002c0000000000000000000000ffff
ffff48454c4c4f0100180011000000000000001100000000000000000000
0000000000504b06062c0000000000000000000000000000000000000001
00000000000000010000000000000033000000000000002e000000000000
00504b0607000000007d0000000000000000000000504b05060000000001
00010033000000ffffffff0000`;

fn void test_zip64_eocd() @test => run_test(&zip64_eocd);
fn void test_zip64_cdfh() @test => run_test(&zip64_cdfh);

fn void run_test(char[] input) => @pool()
{
	ByteReader *br = (ByteReader){}.init(input);
	ByteWriter *bw = (ByteWriter){}.tinit();
	ZipReader zr = zip::topen(br)!!;
	assert(zr.len() == 1);
	assert(zr[0].filename == "HELLO");

	ExtractResult result = zr[0].extract_to(bw, br, true)!!;
	assert(result.bytes == 11);
	assert(result.crc_reported == result.crc_calculated);
	assert(bw.str_view() == "HELLO WORLD");
}


