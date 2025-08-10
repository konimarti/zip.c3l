# zip.c3l — C3 Zip Archive Implementation

## Overview

**`zip.c3l`** is a lightweight library for handling ZIP archive files in
[C3](https://c3-lang.org/). This package makes it easy to read and write ZIP
files natively in C3, with a simple and idiomatic interface. It's especially
useful for C3 projects that need basic ZIP archiving functionality without
relying on external dependencies or heavy native bindings.

## Features

- Read and extract files from ZIP archives.
- Create new ZIP archives and add files.
- Support for ZIP and ZIP64 formats.
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

fn void main() => zip::extract("archive.zip", "output/")!!;
```


### Create a ZIP Archive and Add Files

```c3
import archive::zip;

fn void main()
{
    ZipWriter z = zip::create("output.zip")!!;
    z.add_buffer("document.txt", "Hello World!")!!;
    z.close();
}
```


### List Entries in a ZIP Archive

```c3
import archive::zip;
import std::io;

fn void main()
{
    ZipReader z = zip::open("archive.zip");
    foreach (entry : z) {
	    io::printn(entry.filename);
    }
    z.close();
}
```


## API Reference

- `fn void? zip::extract(String path, String output_dir)`: Extract all files in zip archive to a directory.
- `fn void? zip::write(Path path, OutStream output)`: Create a zip archive with all files in Path and write it to output.

*ZipReader*
- `fn ZipReader? zip::open(String path)`: Open an existing zip archive for reading.
- `fn ZipEntry? ZipReader.get(usz index) @operator([])`: Get the entry at index.
- `fn usz? ZipReader.len() @operator(len)`: Get number of entries.
- `fn usz? ZipReader.extract(ZipEntry entry, OutStream w)`: Extract a specific entry to a stream..
- `fn void ZipReader.close()`: Close the zip archive.

*ZipWriter*
- `fn ZipWriter? zip::create(String path)`: Create a new zip archive for writing.
- `fn void? ZipWriter.add_buffer(String filename, char[] content)`: Add a file with the specified filename and content.
- `fn void ZipWriter.close()`: Close the zip archive and finalize changes.



## License

MIT License.
