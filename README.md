# Zip Archives in C3

## Overview

`zip.c3l` is a lightweight library for handling ZIP and ZIP64 archive files
in [C3](https://c3-lang.org/). This package makes it easy to read and write ZIP
files natively in C3, with a simple interface. It's especially useful for C3
projects that need basic ZIP archiving functionality without relying on
external dependencies or heavy native bindings.

## Features

- Read and extract files from ZIP archives.
- Create new ZIP archives and add files.
- Support ZIP and ZIP64 formats.
- C3 implementation without any external dependencies.
 
## Installation

1. Add to your project:
Clone or add `zip.c3l` as a submodule in your repository.

```sh
git submodule add https://github.com/konimarti/zip.c3l.git
git submodule update --init --recursive
```

2. Update `project.json`:

```json
{
    "dependency-search-paths": [ "lib" ],
    "dependencies": [ "zip" ]
}
```

3. Import in your C3 code:
Import the module where you need zip archive functionality:

```cpp
import archive::zip;
```


## Usage Examples

### Read a ZIP archive

```cpp
import archive::zip;
import std::io;

fn void main() => @pool()
{
    File f = file::open("archive.zip", "rb")!!;
    defer (void) f.close();

    ZipReader reader = zip::topen(&f)!!;
    io::printfn(reader);
}
```

### Extract files to a folder

```cpp
import archive::zip;

fn void main()
{
    File f = file::open("archive.zip", "rb")!!;
    defer (void) f.close();

    zip::extract(&f, "output/")!!;
}
```


### Create a ZIP archive and add files

```cpp
import archive::zip;

fn void main() => @pool()
{
    File f = file::open("archive.zip", "wb")!!;
    defer (void) f.close();

    ZipWriter w = zip::tcreate(&f)!!;
    w.write_buffer("document.txt", "Hello World!")!!;
    w.close();
}
```

### List all filenames

```cpp
import archive::zip;
import std::io;

fn void main() => @pool()
{
    File f = file::open("archive.zip", "rb")!!;
    defer (void) f.close();

    ZipReader reader = zip::topen(&f)!!;
    foreach (entry : reader)
    {
	    io::printn(entry.filename);
    }
}
```
## API Reference

- `fn void? zip::extract(InStream archive, String folder)`: Extract all files in zip archive to a directory.
- `fn void? zip::archive(String path, OutStream output)`: Archive a file or folder to an output stream.

*ZipReader*
- `fn ZipReader? zip::open(Allocator allocator, InStream archive)`: Open an existing zip archive for reading.
- `fn ZipEntry? ZipReader.get(usz index) @operator([])`: Get the entry at index.
- `fn usz? ZipReader.len() @operator(len)`: Get number of entries.
- `fn void ZipReader.free()`: Free the resources.

*ZipWriter*
- `fn ZipWriter? zip::create(Allocator allocator, OutStream output)`: Create a new zip archive for writing.
- `fn void? ZipWriter.write_buffer(String filename, char[] content, ZipCompressMethod method = COMPRESS_STORE)`: Add a file with the specified filename and content.
- `fn void ZipWriter.close()`: Close the zip archive and finalize changes.
- `fn void ZipWriter.free()`: Free the resources.

*ZipEntry*
- `fn LimitReader? ZipEntry.open_compressed(InStream archive)`: Return the compressed data of a specific entry as a readable stream.
- `fn ExtractResult? ZipEntry.extract_to(OutStream output, InStream archive, bool verify_checksum = true)`: Extract a specific entry to an output stream.

Note that some functions that accept an allocator, often have an alternative using the temporary allocator.

## Note for Windows user

Zip archive files should be openend in binary mode (either "rb+" or "wb+").
This ensures that `fseek` works correctly under Windows.
[1](https://stackoverflow.com/questions/47256223/why-does-fseek-0-seek-cur-fail-on-windows).


## License

MIT License.
