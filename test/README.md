# luainstaller Test Programs

This directory contains sample Lua programs used to exercise `luainstaller`
packaging behavior. These applications are packaging targets for binary tools,
similar to PyInstaller-built applications. They are intentionally
application-like rather than unit-test-only fixtures: they should help verify
dependency analysis, LuaRocks module discovery, native module handling, data
files, embedded Web UI, and future onefile runtime extraction.

The test programs are grouped by packaging difficulty.

## Layout

- `single_file/`
  Simple one-file programs. These are basic beginner-level programming tasks
  and are useful first smoke tests for `luai -c`.
- `student_management_system/`
  A classic larger beginner project: a student management system with
  persistent file storage through `cjson`.
- `firebird_web_sql/`
  An interactive web-based remote SQL shell target using Pegasus, `cjson`,
  socket modules, and optional Firebird/LuaSQL support.
- `savinglua/`
  A high-speed Lua table-structure storage database target backed by SQLite.
  This exercises `cjson`, `lsqlite3`, and persistent data files.
- `ltokei/`
  A Lua implementation of a Tokei-like code statistics tool. It may introduce
  normal Lua library dependencies such as `lfs`.

## How To Use

Run samples directly with Lua while developing them:

```sh
lua test/single_file/01_hello_luainstaller.lua
lua test/student_management_system/main.lua
```

Use the current CLI for packaging experiments:

```sh
luai -a test/single_file/01_hello_luainstaller.lua
luai -t test/student_management_system/main.lua
luai -c test/student_management_system/main.lua -o build/student-manager
```

Linux `--onedir` packaging is implemented. The smoke suite packages and runs
selected examples, including native Lua C module targets, and verifies that the
generated bundles can run without a separate `lua` command in a same-ABI
environment.

## Test Growth Rules

- Add the smallest useful program under `single_file/` before adding a complex
  multi-file sample.
- Keep sample dependencies explicit in each directory README.
- Prefer realistic dependency patterns over artificial fixtures.
- If a program needs native modules, document the expected Lua version, OS,
  architecture, and ABI.
- Do not keep historical compatibility samples here. Each directory should map
  to a current packaging target.
