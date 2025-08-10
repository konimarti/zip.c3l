# zip.c3l — C3 Zip Archive Implementation

## Overview

**`zip.c3l`** is a lightweight library for handling ZIP and ZIP64 archive files
in [C3](https://c3-lang.org/). This package makes it easy to read and write ZIP
files natively in C3, with a simple interface. It's especially useful for C3
projects that need basic ZIP archiving functionality without relying on
external dependencies or heavy native bindings.

## Features

- Read and extract files from ZIP archives.
- Create new ZIP archives and add files.
- Support ZIP and ZIP64 formats.
- Pure C3 implementation (no external dependencies).
 
## Installation

1. **Add to your project:**
Clone or add `zip.c3l` as a submodule in your repository.

```sh
git submodule add https://github.com/konimarti/zip.c3l.git
git submodule update --init --recursive
```

2. *Update `project.json`:*

```json
{
    "dependency-search-paths": [ "lib" ],
    "dependencies": [ "zip" ]
}
```

3. **Import in your C3 code:**
Import the module where you need zip archive functionality:

```c3
import archive::zip;
```


## Usage Examples

### Extract All Files from a ZIP Archive

```c3
import archive::zip;

fn void main()
{
    File archive = file::open("archive.zip", "r")!!;
    defer (void) archive.close();

    zip::extract(&archive, "output/")!!;
}
```


### Create a ZIP Archive and Add Files

```c3
import archive::zip;

fn void main()
{
    File archive = file::open("archive.zip", "w")!!;
    defer (void) archive.close();

    ZipWriter w = zip::create(&archive)!!;
    w.add_buffer("document.txt", "Hello World!")!!;
    w.close();
}
```


### List Entries in a ZIP Archive

```c3
import archive::zip;
import std::io;

fn void main()
{
    File archive = file::open("archive.zip", "w")!!;
    defer (void) archive.close();

    ZipReader r = zip::open(&archive)!!;
    foreach (entry : r) {
	    io::printn(entry.filename);
    }
    r.close();
}
```

```c3
import archive::zip;
import std::io;

fn void main() => @pool()
{
    File archive = file::open("archive.zip", "w")!!;
    defer (void) archive.close();

    io::printn( zip::ls(tmem, &archive)!! );
}
```


## API Reference

- `fn void? zip::extract(InStream archive, String folder)`: Extract all files in zip archive to a directory.
- `fn void? zip::archive(String path, OutStream output)`: Archive a file or folder to an output stream.
- `fn PathList? zip::ls(Allocator allocator, InStream archive)`: List files in the zip archive.

*ZipReader*
- `fn ZipReader? zip::open(Allocator allocator, InStream archive)`: Open an existing zip archive for reading.
- `fn ZipEntry? ZipReader.get(usz index) @operator([])`: Get the entry at index.
- `fn usz? ZipReader.len() @operator(len)`: Get number of entries.
- `fn void ZipReader.close()`: Close the zip archive.

*ZipWriter*
- `fn ZipWriter? zip::create(Allocator allocator, OutStream output)`: Create a new zip archive for writing.
- `fn void? ZipWriter.add_buffer(String filename, char[] content, ZipCompressMethod method = COMPRESS_STORE)`: Add a file with the specified filename and content.
- `fn void ZipWriter.close()`: Close the zip archive and finalize changes.

*ZipEntry*
- `fn LimitReader? ZipEntry.compressed_data(InStream archive)`: Return the compressed data of a specific entry as a readable stream.
- `fn usz? ZipEntry.extract_to(InStream archive, OutStream output, bool *checksum = null)`: Extract a specific entry to an output stream.

Note that some functions that accept an allocator, often have an alternative using the temporary allocator.


## License

MIT License.
