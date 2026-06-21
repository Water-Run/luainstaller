# Linux Onedir Demo Validation Design

Date: 2026-06-21

## Purpose

Validate the first useful packaging path for `luainstaller` on the current
Linux host. This stage proves that `luai -c --onedir` can produce runnable
directory bundles for pure Lua and non-pure-Lua examples in this repository.

There is no `Demo/` directory in the current worktree. The repository examples
live under `test/`, so this stage treats those packaging-target samples as the
demo set.

## Scope

In scope:

- Implement Linux `--onedir` bundle output.
- Generate a launcher executable from the existing C launcher generator.
- Embed Lua sources in the launcher through the existing Lua bootstrap path.
- Copy the linked Lua shared runtime into `.luai/native/` so the bundle does
  not require a separate `lua` installation in same-ABI environments.
- Copy detected native Lua C modules into `.luai/native/`.
- Write `.luai/manifest.lua`.
- Make bundled programs prefer `.luai/native/` through `package.cpath`.
- Verify runnable bundles on this Linux host for:
  - `test/runtime_bundle/main.lua`
  - `test/student_management_system/main.lua`
  - `test/savinglua/main.lua`
- Keep optional missing modules, such as `luasql.firebird`, as trace-visible
  optional misses rather than hard failures.

Out of scope:

- `--onefile` archives.
- Windows or macOS bundle output.
- Automatic discovery or copying of every external shared library dependency.
- Removing the dependency on a compatible system/shared Lua runtime.
- Claiming portability beyond same OS, architecture, ABI, and Lua ABI.

## Approach

The bundler reuses the pieces already implemented in earlier milestones:

- `luainstaller.analyzer` discovers Lua and native dependencies.
- `luainstaller.manifest` records source files, destinations, hashes, platform,
  Lua ABI, and compatibility notes.
- `luainstaller.cgen` generates a bootstrap chunk containing Lua sources.
- `luainstaller.launcher` emits C that embeds the bootstrap and runs it through
  the Lua C API.

`src/bundler.lua` will own the filesystem and toolchain work:

1. Build or receive the manifest and analyzed dependencies.
2. Derive module names from analyzer trace records so package-style modules such
   as `savinglua.store` load correctly.
3. Generate C source with a bootstrap that prepends `.luai/native/?.so` and
   `.luai/native/?/init.so` to `package.cpath`.
4. Compile the launcher with `cc`, `pkg-config --cflags --libs lua`, and an
   `$ORIGIN/.luai/native` runtime library search path.
5. Copy the linked Lua shared runtime into `.luai/native/`.
6. Copy native Lua C modules into `.luai/native/`, preserving the basename and
   trace-derived module path when needed.
7. Serialize the manifest as Lua table data to `.luai/manifest.lua`.

The first implementation copies native modules both by basename and, when trace
data contains the requested module name, by module-name path. This supports
simple modules such as `cjson` and nested modules such as `socket.core`.

## API Contract

`luainstaller.bundle(opts)` should return a structured success table when
`opts.mode == "onedir"`:

```lua
{
    ok = true,
    action = "bundle",
    mode = "onedir",
    entry = "...",
    out = "build/app",
    manifest = { ... },
    executable = "build/app/app"
}
```

Invalid options and toolchain failures should remain structured errors. The
`onefile` mode may continue to return `NotImplementedError`.

## Verification

The main evidence for this stage is runtime behavior, not only generated files.
The smoke suite should package and run examples from `test/`, including native
Lua C modules already installed on this Linux host.

Expected commands:

```sh
luac -p src/*.lua
lua test/smoke_all.lua
luarocks make --tree /tmp/luainstaller-rocktree luainstaller-1.0.0-1.rockspec
```

The smoke test may use direct API calls for deterministic bundle creation, but
CLI checks should also confirm that `luai -c --onedir` returns success for at
least one sample.
