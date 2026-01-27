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

fn usz? ZipOutStream.write(&self, char[] bytes) @dynamic
{
	usz n = self.w.write(bytes)!;
	self.written += n;
	return n;
}

fn void? ZipOutStream.write_byte(&self, char c) @dynamic
{
	self.w.write_byte(c)!;
	self.written++;
}

<*
 Pack two bytes into a ushort (little-endian).
 @require p.len >= 2
*>
fn ushort read_le_16(char[] p) @inline => io::read_le_ushort(&&io::wrap_bytes(p))!!;
<*
 Pack four bytes into an uint (little-endian).
 @require p.len >= 4
*>
fn uint read_le_32(char[] p) @inline => io::read_le_uint(&&io::wrap_bytes(p))!!;
<*
 Pack eight bytes into an ulong (little-endian).
 @require p.len >= 8
*>
fn ulong read_le_64(char[] p) @inline => io::read_le_ulong(&&io::wrap_bytes(p))!!;

fn void? write_le_16(OutStream w, ushort s) @inline => io::write_le_short(w, s);
fn void? write_le_32(OutStream w, uint s)   @inline => io::write_le_int(w, s);
fn void? write_le_64(OutStream w, ulong s)  @inline => io::write_le_long(w, s);

<*
 Read n bytes from f and return a String.
*>
fn String? read_n(InStream f, usz n, Allocator allocator) @private => @pool()
{
	if (n == 0) return "";
	char[] buf = allocator::alloc_array(allocator, char, n);
	usz read = 0;
	while (read < n)
	{
		read += f.read(buf[read : n - read])!;
	}
	return (String)buf[:n];
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

	return NOT_FOUND~;
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

	return NOT_FOUND~;
}
