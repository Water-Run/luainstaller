# Implementation Research

This note records the current project map, external references, local
experiments, and implementation direction. It is not an implementation plan yet.

## Current Repository Map

- `src/analyzer.lua` is the strongest current asset. It has a lexer for static
  `require` extraction, path resolution over `package.path` and `package.cpath`,
  native module detection, cycle detection, and topological sorting.
- `src/bundler.lua` and `src/runtime.lua` are empty. They are the natural places
  for the next packaging and startup work.
- `src/cli.lua` still exposes the older verbose command style (`analyze`,
  `build`, `engines`, `logs`) and requires installed module paths. Running it
  directly from the checkout does not work with the current flat `src/` layout.
- `src/init.lua` still calls missing `luainstaller.executor` and
  `luainstaller.wrapper` modules.
- `luainstaller-1.0.0-1.rockspec` references missing modules and currently lacks
  `rockspec_format = "3.0"` even though it uses the `labels` field.
- The README now describes the resumed direction, but older sections still
  describe `bundle` and long-form CLI names. Those sections should be aligned
  when the CLI design is finalized.

## External Reference Map

`luastatic` is the closest small reference. Its README describes a standalone
executable builder that embeds Lua and runs without a target-machine Lua
installation. Its implementation generates C source, embeds Lua code as byte
arrays, installs a bundled Lua searcher, creates `arg`, and runs the entry chunk.
It also uses `nm` to detect `luaopen_*` symbols in binary modules.

`luapak` is a larger reference point. It installs LuaRocks dependencies, builds
Lua/C modules as static libraries, analyzes required modules, merges Lua source,
generates a C wrapper, and links everything. It proves that a more complete Lua
packaging system exists, but it is much broader than this project's first stage.

Evo's standalone executable documentation is useful for the extraction model:
the executable contains an archive, adds a loader/searcher, and can extract
native libraries before loading them through Lua's normal mechanisms.

Project positioning: luainstaller is not unique in the sense that Lua
standalone builders already exist. Its useful niche can be a smaller
LuaRocks-installed library plus `luai` command that focuses on understandable
same-platform packaging, dependency tracing, and simple native-module handling
without becoming a full build distribution.

References:

- https://github.com/ers35/luastatic
- https://github.com/jirutka/luapak
- https://evo-lua.github.io/docs/how-to-guides/standalone-executables/

## Local Experiments

Environment:

- `lua -v`: Lua 5.4.8.
- `luarocks --version`: LuaRocks 3.13.0.
- `luastatic`: installed at `/usr/bin/luastatic`, version 0.0.12.
- `busted`: installed, version 2.2.0.

Analyzer behavior:

- `test/demo-programs/helloluainstaller/hello_luainstaller.lua` resolves with no
  dependencies.
- `test/demo-programs/management/main.lua` resolves three Lua dependencies:
  `model.lua`, `utils.lua`, and `service.lua`.
- `test/demo-programs/sqltui/entry.lua` currently fails on unresolved `bit`
  through an installed `ltui` dependency. This is a useful trace case: strict
  static analysis needs either compatibility knowledge, optional dependency
  handling, or user-visible include/exclude guidance.
- A temporary project with `require("mymod")` and a local `mymod.so` was
  resolved as one native library. This confirms that the analyzer can already
  provide the native module list needed by the runtime extraction path.

LuaRocks behavior:

- `luarocks make --tree <tmp> luainstaller-1.0.0-1.rockspec` currently fails
  before module installation because the rockspec uses `labels` without
  declaring rockspec format 3.0.

## First-Stage Shape

The first useful version should stay deliberately narrow:

- Installation is via LuaRocks.
- Library import remains `require("luainstaller")`.
- LuaRocks registers a concise CLI named `luai`.
- CLI shape:
  - `luai -c main.lua` packages.
  - `luai -a main.lua` analyzes.
  - `luai -t main.lua` traces dependency resolution.
  - `-o <path>` selects output.
  - `-i <path>` includes an extra file.
  - `-x <path-or-module>` excludes a false positive.
- Compatibility promise is same OS, same architecture, same ABI.

## Candidate Architecture

1. Analyzer front end

   Keep `src/analyzer.lua`, but add a trace-capable mode that records:

   - requiring script
   - source line
   - requested module name
   - candidate search paths
   - selected path and type
   - reason for skipping or failure

2. Bundle manifest

   Produce an explicit manifest table:

   - entry script
   - Lua modules
   - native Lua C modules
   - extra included files
   - output mode
   - target compatibility notes

3. Directory mode

   Generate a small executable plus a bundle directory. Copy native modules into
   a predictable `lib/` or `.luai/lib/` directory and update `package.cpath`
   before running the entry script.

4. Onefile mode

   Use a small C launcher with an embedded archive or byte-array payload. On
   startup, extract native modules to a temp directory, prepend that directory
   to `package.cpath`, install a Lua module searcher for embedded Lua source,
   then run the entry.

5. luastatic-inspired C integration

   Reuse the idea, not the whole tool:

   - embed Lua chunks as byte arrays with explicit lengths
   - install a searcher at index 2
   - create the `arg` table
   - use an error handler that prints traceback
   - optionally detect static Lua C modules by `luaopen_*` symbols if `.a`
     support is added later

6. Native modules

   First-stage native support should handle dynamic Lua C modules
   (`.so`, `.dll`, `.dylib`) by extraction and `package.cpath`. Static `.a`
   linking can come later because symbol registration and dependent library
   ordering are more fragile.

## Main Risks

- Lua C module ABI mismatch. This must be reported as a compatibility boundary,
  not hidden as a generic load failure.
- Optional dependencies. Some projects probe modules with `pcall(require, ...)`;
  trace output should make it easy to decide whether to include or exclude.
- External dynamic libraries. A Lua C module may depend on other shared
  libraries that are not Lua modules. First-stage support should not pretend to
  solve this automatically.
- Windows XP targets. The build machine, compiler runtime, Lua runtime, and
  native modules must all be compatible with XP. Lua source compatibility alone
  is not enough.

## Next Implementation Questions

- Should source layout be changed to `src/luainstaller/*.lua`, or should tests
  always run through a generated LuaRocks tree?
- Should `luai -c` default to directory mode first, or onefile mode first?
- Should the first C launcher be checked in as hand-written C, or generated
  entirely from Lua templates?
- Should trace output be text-first, JSON-first, or both?
