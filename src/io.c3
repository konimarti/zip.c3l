module archive::zip;

import std::io;

<*
 Wrapped OutStream to provide number of written bytes.
*>
struct ZipOutStream (OutStream)
{
	OutStream w;
	ulong written;
}

fn ulong ZipOutStream.tell(&self) => self.written;

fn usz? ZipOutStream.write(&self,  char[] bytes) @dynamic
{
	usz? n = self.w.write(bytes);
	if (try n) self.written += n;
	return n;
}

fn void? ZipOutStream.write_byte(&self, char c) @dynamic
{
	if (catch err = self.w.write_byte(c)) return err?;
	self.written++;
}

<*
 Pack two bytes into a ushort (little-endian).

 @require p.len >= 2
*>
macro ushort read_le_16(char[] p)
{
	return ((ushort) p[0]) | ((ushort) p[1] << 8);
}

<*
 Pack four bytes into an uint (little-endian).

 @require p.len >= 4
*>
macro uint read_le_32(char[] p)
{
	return ((uint) p[0]) |
		((uint) p[1] << 8) |
		((uint) p[2] << 16) |
		((uint) p[3] << 24);
}

<*
 Pack eight bytes into an ulong (little-endian).

 @require p.len >= 8
*>
macro ulong read_le_64(char[] p)
{
	return ((ulong) p[0]) |
		((ulong) p[1] << 8) |
		((ulong) p[2] << 16) |
		((ulong) p[3] << 24) |
		((ulong) p[4] << 32) |
		((ulong) p[5] << 40) |
		((ulong) p[6] << 48) |
		((ulong) p[7] << 56);
}

<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_16(stream, ushort s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
}
<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_32(stream, uint s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
	stream.write_byte((char)(s >> 16))!;
	stream.write_byte((char)(s >> 24))!;
}

<*
 @require io::@is_outstream(stream)
*>
macro void? write_le_64(stream, ulong s)
{
	stream.write_byte((char)s)!;
	stream.write_byte((char)(s >> 8))!;
	stream.write_byte((char)(s >> 16))!;
	stream.write_byte((char)(s >> 24))!;
	stream.write_byte((char)(s >> 32))!;
	stream.write_byte((char)(s >> 40))!;
	stream.write_byte((char)(s >> 48))!;
	stream.write_byte((char)(s >> 56))!;
	stream.write_byte((char)(s >> 56))!;
}

<*
 Read n bytes from f and return a String.
*>
fn String? read_n(InStream f, usz n, Allocator allocator) @private => @pool()
{
	if (n == 0) return "";
	char[] buf = mem::talloc_array(char, n);
	usz read = 0;
	while (read < n)
	{
		read += f.read(buf[read : n - read])!;
	}
	return ((String)buf[:n]).copy(allocator);
}

<*
 Scan from the end of the file for signature.
*>
fn usz? find_signature_r(InStream in, char[4] sig)
{
	usz i, n, size, offset;
	char[256] buf;

	size = in.seek(offset, Seek.END)!;

	offset = 0;
	while (offset < size)
	{
		offset += 128;
		if (offset > size) offset = size;
		in.seek(-offset, Seek.END)!;
		n = in.read(&buf)!;

		// Scan for end record magic number
		if (try loc = ((String)buf[:n]).index_of((String)sig[..]))
		{
			return size - offset + loc;
		}
	}

	return NOT_FOUND?;
}

<*
 Scan from the current file cursor for a signature.
*>
fn usz? find_next_signature(InStream in, char[4] sig)
{
	usz n;
	char[256] buf;

	while (try read = in.read(&buf) && read > 0)
	{
		n += read;

		// Scan for Signature
		if (try loc = ((String)buf[:read]).index_of((String)sig[..]))
		{
			return in.seek(0,Seek.CURSOR)! - read + loc;
		}
	}

	return NOT_FOUND?;
}
