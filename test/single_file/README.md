# single_file

This directory contains small, independent, single-file Lua programs. They are
intended to be the first smoke tests for `luainstaller` because they do not need
module resolution beyond Lua's standard libraries.

Start here:

```sh
lua test/single_file/01_hello_luainstaller.lua
luai -c test/single_file/01_hello_luainstaller.lua
```

Planned coverage:

- console output
- numeric input and formatting
- table processing
- file reading and writing
- deterministic pseudo-random behavior
- basic command-line arguments

The files are deliberately simple. Each should remain understandable without
opening any other source file.
