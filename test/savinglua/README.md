# savinglua

This directory is reserved for a high-speed Lua table-structure storage
database. The sample should eventually include both Lua code and C code.

Purpose:

- exercise mixed Lua/C project packaging
- verify native module discovery
- verify runtime extraction and `package.cpath` setup
- provide a realistic benchmark-style sample

Planned layout:

- `src/` for Lua modules
- `csrc/` for C modules
- `bench/` for benchmark scripts and generated data

The code is intentionally not initialized yet. Add the smallest working storage
prototype before adding benchmark cases.
