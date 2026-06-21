# Linux Onedir Bundling

This document describes the current Linux `--onedir` implementation, how it
packages pure Lua and non-pure-Lua projects, how to verify generated bundles,
and what remains outside the current support boundary.

For lab results across Linux, macOS, and Windows hosts, see
`docs/CROSS-PLATFORM-TEST-MATRIX.md`.

## Status

Linux `--onedir` is the first implemented bundle target. It is designed for the
same host family that produced the bundle:

- same OS;
- same architecture;
- same C ABI;
- same Lua ABI;
- same compiler-runtime family for native components.

The generated bundle does not require a separate `lua` command on the target
environment. The linked Lua shared runtime is copied into the bundle and found
through the launcher's `$ORIGIN/.luai/native` runtime search path.

`--onefile`, cross-platform output, Windows output, and automatic external
shared-library closure are not implemented in this stage.

## Output Layout

For:

```sh
luai -c --onedir test/savinglua/main.lua -o dist/savinglua
```

the output layout is:

```text
dist/savinglua/
    savinglua
    .luai/
        manifest.lua
        native/
            liblua-5.4.so
            cjson.so
            lsqlite3.so
            ...
        build/
            launcher.c
```

The executable name is derived from the output directory basename. The
`.luai/build/launcher.c` file is retained for inspection and troubleshooting.

## Build Pipeline

The implementation is intentionally layered:

1. `luainstaller.analyzer` scans static `require` calls and resolves candidates
   from `package.path` and `package.cpath`.
2. `luainstaller.trace` records requiring file, source line, requested module,
   candidates, selected path, selected type, classification, and reason.
3. `luainstaller.manifest` creates the manifest contract with normalized paths,
   content hashes, output settings, Lua version, platform, and compatibility
   notes.
4. `luainstaller.cgen` embeds Lua sources into a bootstrap chunk and installs a
   bundled Lua searcher.
5. `luainstaller.launcher` emits C source that embeds the bootstrap as a byte
   array and runs it through the Lua C API.
6. `luainstaller.bundler` writes the onedir layout, compiles the launcher, copies
   the linked Lua shared runtime, copies native Lua C modules, and writes
   `.luai/manifest.lua`.

## Runtime Flow

At process startup:

1. The ELF loader finds the copied Lua shared runtime through the launcher's
   `$ORIGIN/.luai/native` RUNPATH.
2. The C launcher creates a Lua state, opens the standard libraries, creates
   `arg`, installs a traceback handler, and runs the embedded bootstrap.
3. The bootstrap prepends these patterns to `package.cpath`:

   ```text
   <bundle-dir>/.luai/native/?.so
   <bundle-dir>/.luai/native/?/init.so
   ```

4. The bootstrap installs a bundled Lua source searcher ahead of the normal
   filesystem searchers.
5. The entry chunk runs with user arguments preserved.

Pure Lua modules are loaded from the embedded payload. Native Lua C modules are
loaded from `.luai/native/` as real files.

## Non-Pure-Lua Packaging

Native Lua C modules cannot be loaded from ordinary Lua strings. They must be
present as filesystem files because Lua's native loader uses the platform's
dynamic loader.

Examples:

```lua
require("cjson")
require("lsqlite3")
require("socket.core")
require("_openssl")
```

Typical resolved files:

```text
/usr/lib64/lua/5.4/cjson.so
/usr/lib64/lua/5.4/lsqlite3.so
/usr/lib64/lua/5.4/socket/core.so
/usr/lib64/lua/5.4/_openssl.so
```

The bundler copies each detected native module into `.luai/native/`. For nested
module names, it also preserves a module-name path so normal `package.cpath`
matching works:

```text
require("socket.core")
    -> .luai/native/core.so
    -> .luai/native/socket/core.so
```

The flat copy is useful for diagnostics and simple module names. The nested copy
matches Lua's `?` replacement behavior for names containing dots.

## Lua Shared Runtime

The launcher is a shared-Lua executable in this stage. After compilation,
`bundler` runs `ldd` on the executable, finds the linked `liblua*.so`, copies it
to `.luai/native/`, and records it in the manifest:

```lua
launcher = {
    profile = "shared-lua",
    lua_runtime = {
        source_path = "/usr/lib64/liblua-5.4.so",
        destination_path = ".luai/native/liblua-5.4.so",
    },
}
```

This is what allows bundles to run in a same-ABI environment that has no `lua`
command installed.

## Manifest

`.luai/manifest.lua` is a Lua table. It records:

- entry source and destination metadata;
- output mode and output path;
- Lua version and Lua ABI note;
- OS and architecture;
- launcher profile and copied Lua runtime;
- Lua modules;
- native Lua C modules;
- manual include/exclude settings;
- analyzer trace records;
- compatibility notes;
- file hashes for recorded source files.

The manifest is the contract later `--onefile`, diagnostics, compatibility
checks, and native dependency features should reuse.

## Verified Examples

The smoke suite packages and runs:

- `test/runtime_bundle/main.lua` - pure Lua multi-file bundle;
- `test/student_management_system/main.lua` - uses `cjson`;
- `test/savinglua/main.lua` - uses `cjson` and `lsqlite3`;
- `test/firebird_web_sql/server.lua` - uses Pegasus, `cjson`, `socket.core`,
  and optional `luaossl`;
- `test/ltokei/main.lua` - uses `lfs`.

Additional clean-environment verification was run in a container without a
`lua` command. `ldd` showed the launcher loading `liblua-5.4.so` from
`.luai/native/`, and the packaged examples ran there.

## Commands

Install with LuaRocks:

```sh
luarocks install luainstaller
```

Install from source when LuaRocks is unavailable:

```sh
sh tools/install-source.sh --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
luai --help
```

The source installer copies the Lua modules into the selected prefix and writes
a `luai` wrapper that sets `LUA_PATH` before invoking Lua. It does not install
native Lua modules, Lua headers, or compiler metadata.

Build a bundle:

```sh
luai -c --onedir test/savinglua/main.lua -o /tmp/savinglua-bundle --max-deps 250
```

Run it:

```sh
/tmp/savinglua-bundle/savinglua \
  --db /tmp/savinglua.sqlite3 \
  put users:ada '{"name":"Ada Lovelace","score":98}'
```

Inspect dynamic dependencies:

```sh
ldd /tmp/savinglua-bundle/savinglua
readelf -d /tmp/savinglua-bundle/savinglua | grep -E 'RPATH|RUNPATH'
```

Inspect the manifest:

```sh
lua -e 'local m = dofile("/tmp/savinglua-bundle/.luai/manifest.lua"); print(m.launcher.lua_runtime.destination_path)'
```

## Limitations

Current limitations are explicit:

- Linux only.
- `--onefile` is not implemented.
- Native module external dependencies are not closed automatically. For example,
  an `.so` may still depend on system `libsqlite3.so.0`, `libssl.so.3`, or other
  libraries.
- Bundles are not cross-distribution artifacts. The tested promise is same OS,
  architecture, ABI, Lua ABI, and compatible system libraries.
- Dynamic `require(variable)` is rejected by the analyzer. Use `--include` for
  dependencies static analysis cannot see.
- Optional probes through `pcall(require, "...")` are traced as optional missing
  modules when unresolved.
- The generated launcher uses a shared Lua profile. Static Lua linking is still
  roadmap work.
- The source installer is not a replacement for the build toolchain. Hosts
  without Lua headers or Lua `pkg-config` metadata can run analysis but cannot
  compile the C launcher.
- Windows and macOS output are not implemented in this stage.

## Onefile Direction

The future `--onefile` path should reuse the same manifest and runtime contract:

1. Store the manifest, Lua payload, native Lua C modules, and Lua shared runtime
   in an embedded archive or appended payload.
2. At startup, validate the payload and extract native components to a temporary
   or content-addressed cache directory.
3. Set `package.cpath` to that extraction directory.
4. Run the same bootstrap searcher for embedded Lua modules.
5. Preserve the user program's exit status and report cleanup failures without
   hiding the original program result.

For Windows bundles that need `lua55.dll`, the safer design is a two-stage
launcher: an outer extractor with no Lua DLL dependency writes an inner onedir
layout, then starts the real launcher from that directory.
