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
  and should be the first smoke tests for `luai -c`.
- `student_management_system/`
  A classic larger beginner project: a student management system with
  persistent file storage. It is planned to use `cjson` for structured storage.
- `firebird_web_sql/`
  An interactive web-based remote SQL shell target. It is intended to use a
  Firebird database driver and the Pegasus web library.
- `savinglua/`
  A high-speed Lua table-structure storage database target backed by SQLite.
  This area is expected to include Lua and native SQLite-facing code.
- `ltokei/`
  A Lua implementation of a Tokei-like code statistics tool. It may introduce
  normal Lua library dependencies.

## How To Use

Run samples directly with Lua while developing them:

```sh
lua test/single_file/01_hello_luainstaller.lua
lua test/student_management_system/main.lua
```

Use the future CLI shape for packaging experiments:

```sh
luai -a test/single_file/01_hello_luainstaller.lua
luai -t test/student_management_system/main.lua
luai -c test/student_management_system/main.lua -o build/student-manager
```

Current code may not yet match the future `luai` interface. These examples
document the target structure and expected workflows.

## Test Growth Rules

- Add the smallest useful program under `single_file/` before adding a complex
  multi-file sample.
- Keep sample dependencies explicit in each directory README.
- Prefer realistic dependency patterns over artificial fixtures.
- If a program needs native modules, document the expected Lua version, OS,
  architecture, and ABI.
- Do not keep historical compatibility samples here. Each directory should map
  to a current packaging target.
