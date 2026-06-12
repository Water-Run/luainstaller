# savinglua

This directory is reserved for a high-speed Lua table-structure storage
database backed by SQLite. The sample should eventually include Lua code and
native SQLite-facing code.

Purpose:

- exercise mixed Lua/C project packaging
- exercise SQLite-backed persistence
- verify native module discovery
- verify runtime extraction and `package.cpath` setup
- provide a realistic benchmark-style sample

Planned layout:

- `src/` for Lua modules
- `csrc/` for C modules or SQLite binding glue
- `bench/` for benchmark scripts and generated data

The code is intentionally not initialized yet. The first prototype should store
Lua table records in SQLite before adding benchmark cases.
