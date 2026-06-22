# Onefile And Require Engine Design

## Goal

Implement `--onefile` bundles while preserving the existing same-environment
compatibility promise, and make dependency discovery selectable through
`--require-engine`.

## Scope

This milestone includes:

- `--require-engine static`, using the current static dependency analyzer.
- `--require-engine manual`, using only explicit manual inputs.
- `--require-engine runtime`, running the entry script once with a traced
  `require` function and packaging the modules observed during that run.
- `--onefile` for Linux, macOS, and Windows profiles by generating a native
  extractor executable that recreates an inner onedir layout before launching
  the inner program.

This milestone does not include arbitrary dynamic require proof, automatic
external shared-library closure, bytecode compilation, compression, or
cross-ABI portability.

## Require Engine Semantics

`static` is the default and keeps current behavior. It scans static `require`
forms through `luainstaller.analyzer`.

`manual` disables automatic scanning and uses `include` only. The existing
`--no-depscan` option remains a compatibility alias for this engine.

`runtime` runs the entry program during the build with optional `run_args`.
During that run, `require` is wrapped. Every requested module name is recorded,
then resolved with the existing analyzer resolver so Lua and native modules
flow through the same manifest and bundler code as static dependencies. Runtime
discovery is path-sensitive: it only sees code paths that execute during this
build-time run.

For CLI syntax, arguments after `--` are runtime discovery arguments:

```sh
luai -c --onefile app.lua --require-engine runtime -- seed --verbose
```

## Onefile Architecture

The onefile implementation uses a two-stage layout:

1. Build the normal `--onedir` bundle in a temporary staging directory.
2. Generate a C extractor that embeds all regular files from that staged
   directory.
3. At runtime, the extractor writes files to a cache directory derived from the
   embedded payload hash.
4. The extractor starts the inner launcher from that extracted directory,
   forwards user arguments, waits for completion, and returns the same exit
   code.

This design is intentionally close to PyInstaller onedir-to-onefile behavior.
It works for native Lua C modules because `.so`, `.dylib`, and `.dll` files are
materialized before Lua user code runs. It also works for Windows Lua DLL
profiles because the outer extractor does not link to Lua and the inner
launcher only starts after `lua54.dll` has been written beside it.

## Extraction Rules

The first implementation uses content-addressed cache directories under:

- POSIX: `${TMPDIR:-/tmp}/luainstaller-onefile/<payload-id>/`
- Windows: `%TEMP%\luainstaller-onefile\<payload-id>\`

Each embedded file carries a relative path, byte length, and FNV-1a hash. The
extractor creates parent directories, rewrites files whose content hash does
not match, and leaves existing matching files in place. Files marked executable
by the build side are chmodded on POSIX. Cleanup is not attempted by default;
content-addressed reuse avoids stale mixed payloads.

## Files And Boundaries

- `src/require_engine.lua` owns dependency discovery strategy selection.
- `src/onefile.lua` owns staging, embedded file collection, extractor C source
  generation, and extractor compilation.
- `src/init.lua` wires `require_engine` into `analyze`, `trace`, and `bundle`.
- `src/cli.lua` parses `--require-engine` and `--` runtime arguments.
- `src/bundler.lua` remains the onedir implementation and is reused by onefile.
- `test/smoke_all.lua` verifies static, manual, runtime, and onefile flows.

## Error Handling

Invalid engines return `InvalidOptionsError`. Runtime discovery failures return
`RequireEngineError` with captured command output. Extractor compile failures
return `CompilationFailedError`. Unsupported target profiles continue to return
the existing platform/toolchain errors from onedir staging.

## Testing

The smoke suite must cover:

- `--require-engine static` preserving current output.
- `--require-engine manual` with a manually included Lua dependency.
- `--require-engine runtime` discovering a module selected during execution.
- Pure Lua `--onefile` builds and runs.
- Native-module `--onefile` builds and runs for the local platform.
- Syntax checks for generated Lua and shell scripts continue to pass.
