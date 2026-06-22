# ROAD_MAP

This document records the implementation direction for `luainstaller`.

The project goal is not to stay pure Lua. Lua should remain the control plane,
while C should be used for the parts that require process startup, embedded Lua
state control, native module loading, and self-extraction.

## Goal

Build `luainstaller` into a packaging tool that can produce same-environment,
out-of-the-box executables for pure Lua and non-pure-Lua projects. The current
release remains Lua 5.4-compatible; Lua 5.5.0 is the forward-looking language
baseline for later release work.

The useful compatibility promise is:

- Same OS.
- Same architecture.
- Same ABI.
- Same Lua ABI.
- Same compiler-runtime family for native components.

The target machine should not need a separate Lua installation, but native
module compatibility must still be treated as a real ABI boundary.

## Baseline Decisions

- Current project code and the rockspec stay compatible with Lua 5.4 or newer.
- Lua 5.5.0 is a roadmap target, not a requirement for the current release.
- The CLI command should be `luai`.
- The library import should remain `require("luainstaller")`.
- `--onedir` should be implemented before `--onefile`.
- Non-pure-Lua support means dynamic Lua C modules must be handled as real
  filesystem files at runtime.
- Windows XP compatibility is a build profile, not a generic promise from Lua
  source compatibility alone.
- Old Windows builds must avoid a dependency on a new Windows C runtime.

## Reference Direction

`luastatic` is the main reference for the pure Lua path:

- Generate C.
- Embed Lua source as byte arrays with explicit lengths.
- Create a Lua state.
- Open standard libraries.
- Create `arg`.
- Install a bundled Lua searcher.
- Run the entry chunk with traceback handling.

`luainstaller` should reuse that idea, not simply wrap `luastatic`.

The real difference is native modules:

- `.dll`, `.so`, and `.dylib` modules cannot be loaded directly from embedded
  memory through normal Lua loading rules.
- They must exist as files.
- Their dependent libraries may also need real paths.
- Their Lua C API symbols must come from a compatible Lua runtime.

That makes the PyInstaller-like `--onedir` and `--onefile` behavior the main
technical challenge.

## Architecture

### Lua Control Plane

Lua owns the user-facing and build-planning layer:

- CLI parsing for `luai -a`, `luai -t`, and `luai -c`.
- Dependency analysis from static `require`.
- Trace output for every module-resolution decision.
- Manifest generation.
- Include/exclude handling.
- Build orchestration.
- Archive generation for `--onefile`.
- Structured API results.

The existing `src/analyzer.lua` is the strongest current base and should be
extended, not replaced.

### C Runtime Layer

C owns the runtime layer:

- Create and close the Lua state.
- Open selected Lua standard libraries.
- Create `arg`.
- Install bundled Lua searchers before normal filesystem searchers.
- Load and run the entry chunk.
- Print readable traceback errors.
- Locate the executable path.
- Locate adjacent `.luai` data for `--onedir`.
- Locate or read embedded payload data for `--onefile`.
- Extract native modules when needed.
- Rewrite `package.path` and `package.cpath`.
- Clean temporary extraction directories where safe.

Keep C small and auditable. Platform-specific behavior should sit behind small
helpers such as:

- `li_get_executable_path`
- `li_make_temp_dir`
- `li_write_file`
- `li_set_native_search_path`
- `li_remove_tree`

### Manifest

Every bundle should be driven by a manifest.

The manifest should record:

- Entry script.
- Lua modules.
- Native Lua C modules.
- Explicitly included external files.
- Output mode.
- Lua version.
- Lua ABI note.
- OS.
- Architecture.
- Launcher profile.
- Source path.
- Bundle destination path.
- Content hash.
- Compatibility notes.

The manifest is the contract between analyzer, bundler, launcher, trace output,
and diagnostics.

## Lua Runtime ABI Strategy

Dynamic Lua C modules must be able to resolve Lua C API symbols. Finding the
module file is not enough.

Support these launcher profiles:

### Static-Lua Launcher

The executable links `liblua.a` into the launcher.

This is best for:

- Pure Lua bundles.
- Future static native module support.
- Unix-like dynamic native modules when host Lua symbols are exported correctly.

This profile is closest to `luastatic`.

### Shared-Lua Launcher

The executable uses the same shared Lua runtime that native modules were built
against.

On Windows this usually means `lua55.dll`. For old-system targets, that DLL
must be built with the same compatible C runtime policy as the launcher.

This is the safer first profile for Windows dynamic native modules.

### Two-Stage Windows Onefile

Windows cannot safely load an imported `lua55.dll` after the process has already
started if the real launcher imports it at process startup.

For onefile bundles that need `lua55.dll`, use a two-stage design:

1. Outer extractor starts first and does not depend on `lua55.dll`.
2. Outer extractor writes an inner onedir layout to a temp directory.
3. Inner layout contains the real launcher, `lua55.dll`, Lua C modules, and
   manifest.
4. Outer extractor starts the inner launcher from that directory.

This avoids pretending that a required process-startup DLL can be extracted
after it was already needed.

## Native Module Contract

The first native module contract should be narrow and explicit:

- Analyzer finds Lua C modules through `package.cpath`.
- Manifest records requested module name, resolved source path, extension, and
  destination path.
- `--onedir` copies native modules into `.luai/native/`.
- `--onefile` stores native modules in payload and extracts them before user
  code runs.
- Runtime prepends native directories to `package.cpath`.
- Runtime records whether Lua C API symbols come from host exports, `lua55.dll`,
  a platform shared Lua library, or static registration.
- Runtime reports likely Lua ABI, OS, architecture, or compiler-runtime mismatch
  as compatibility errors when metadata makes that possible.

External dynamic libraries are separate:

- Windows companion DLLs may be copied beside the Lua C module when explicitly
  included.
- Linux `.so` dependencies are only reliable when the module was built with
  suitable runtime paths such as `$ORIGIN`, or when the same environment already
  provides them.
- macOS `.dylib` dependencies need install-name handling such as
  `@loader_path`; this should be documented before it is automated.

Do not claim automatic dependency closure in the first release.

## Output Modes

### `--onedir`

This is the first implementation target.

Recommended layout:

```text
dist/app/
    app[.exe]
    .luai/
        manifest.lua
        lua/
        native/
        data/
```

Why first:

- Native modules can be copied as real files.
- Debugging is easier.
- The runtime does not need archive parsing yet.
- It directly tests the same-environment promise.

### `--onefile`

This comes after `--onedir`.

The onefile implementation should reuse the same manifest and runtime contract.
The payload can be appended to the executable or generated as byte arrays.

Rules:

- Pure Lua modules can stay embedded.
- Dynamic native modules must be extracted.
- Windows bundles needing `lua55.dll` should use the two-stage design.
- Extraction paths must be per-run or content-addressed with hash checks.
- Cleanup failure should be reported but should not hide the real program exit
  status.

## Development Phases

### Phase 1: Baseline And Policy

- [ ] Keep current release docs explicit about Lua 5.4+ compatibility while
      tracking Lua 5.5.0 as a roadmap target.
- [ ] Revisit the Lua baseline once the toolchain and dependency ecosystem make
      Lua 5.5.0 a practical release requirement.
- [ ] Document old-system support as a build profile.
- [ ] Define Linux host, current Windows host, and Windows XP-compatible MinGW
      profiles.
- [ ] Remove missing `executor.lua` and `wrapper.lua` from rockspec until they
      exist.
- [ ] Register the CLI as `luai`.

### Phase 2: Public API And CLI Reset

- [ ] Replace old CLI commands with `luai -a <entry>`, `luai -t <entry>`, and
      `luai -c <entry>`.
- [ ] Add `--onedir`, `--onefile`, `-o <path>`, `--include <path>`,
      `--exclude <path-or-module>`, `--no-depscan`, and `--verbose`.
- [ ] Make `--onedir` the default output mode.
- [ ] Expose `luainstaller.analyze(opts)`, `luainstaller.trace(opts)`, and
      `luainstaller.bundle(opts)`.
- [ ] Return structured API results.

### Phase 3: Traceable Analyzer

- [ ] Keep the existing lexer and resolver.
- [ ] Add trace records with requiring file, source line, requested module,
      candidate templates, selected path, selected type, and skip/failure
      reason.
- [ ] Classify modules as `builtin`, `lua`, `native`, `external`, `missing`, or
      `excluded`.
- [ ] Treat `pcall(require, "...")` as optional in trace output.
- [ ] Preserve dependency-limit and circular-dependency errors.

### Phase 4: Bundle Manifest

- [ ] Create `src/manifest.lua`.
- [ ] Convert analyzer output, includes, excludes, and output options into a
      manifest table.
- [ ] Store Lua version, Lua ABI note, OS, architecture, output mode, launcher
      profile, and content hashes.
- [ ] Use normalized forward-slash paths inside the manifest.
- [ ] Reject ambiguous duplicate module names unless explicitly resolved.

### Phase 5: Pure Lua Runtime Searcher

- [ ] Create `src/runtime.lua` and `src/cgen.lua`.
- [ ] Generate a Lua bootstrap chunk that installs a bundled searcher.
- [ ] Support Lua source chunks by module name and entry id.
- [ ] Strip UTF-8 BOM and shebang before loading source.
- [ ] Preserve `arg` semantics.
- [ ] Verify single-file and multi-file pure Lua samples.

### Phase 6: C Launcher Template

- [x] Add `src/launcher/luai_launcher.c`.
- [ ] Add platform helpers for POSIX and Windows.
- [x] Implement Lua state creation, selected library opening, `arg`, traceback,
      and entry execution.
- [x] Embed Lua chunks with explicit byte lengths.
- [ ] Support static-Lua launcher profile.
- [x] Support shared-Lua launcher profile.
- [ ] Avoid new Windows CRT assumptions.

### Phase 7: `--onedir` Bundler

- [x] Create `src/bundler.lua`.
- [x] Build output directory with executable plus `.luai/`.
- [ ] Copy Lua payload according to manifest.
- [x] Copy native modules to `.luai/native/`.
- [x] Copy `lua55.dll` or platform Lua shared library when needed.
- [x] Write `.luai/manifest.lua`.
- [x] Prepend `.luai/native` patterns to `package.cpath`.

### Phase 8: Native Module Fixture

- [ ] Add `test/native_module/`.
- [ ] Create a tiny Lua C module with `luaopen_native_hello`.
- [ ] Build it as a dynamic module for the current platform.
- [ ] Verify direct Lua execution.
- [ ] Verify analyzer detects it as native.
- [ ] Verify `luai -c --onedir` packages and runs it.

### Phase 9: `--onefile` Payload

- [ ] Create `src/archive.lua`.
- [ ] Define deterministic archive format with magic bytes, version, file table,
      file data, sizes, and hashes.
- [ ] Append archive to executable or embed it as generated byte arrays.
- [ ] Teach launcher to locate and validate payload.
- [ ] Extract native modules before user code.
- [ ] Use two-stage extraction on Windows when `lua55.dll` is required.

### Phase 10: Extraction And Cleanup

- [ ] Create collision-resistant per-run temp directories.
- [ ] Write native modules atomically where possible.
- [ ] Reuse extraction only when hashes match and cache mode is enabled.
- [ ] Clean temp directories on normal exit.
- [ ] Leave readable diagnostics when cleanup fails.
- [ ] Verify repeated onefile runs do not use stale modules.

### Phase 11: Compatibility Diagnostics

- [ ] Create `src/compat.lua`.
- [ ] Record Lua version and Lua ABI notes in every manifest.
- [ ] Record whether Lua API symbols come from host exports, `lua55.dll`, shared
      Lua library, or static registration.
- [ ] Detect obvious OS and architecture mismatches.
- [ ] Warn about likely external-library dependencies.
- [ ] Add a `luai -t` section explaining same OS, architecture, and ABI.

### Phase 12: Explicit External Libraries

- [ ] Support explicit `--include` for companion `.dll`, `.so`, and `.dylib`
      files.
- [ ] Preserve relative placement beside the Lua C module when requested.
- [ ] On Windows, make bundled companion DLLs discoverable.
- [ ] On Linux, document `$ORIGIN` or same-environment requirements.
- [ ] On macOS, document `@loader_path`.
- [ ] Avoid claiming full automatic native dependency closure.

### Phase 13: Static Native Module Mode

- [ ] Add experimental `src/staticlink.lua`.
- [ ] Support `.a` and `.o` Lua C modules.
- [ ] Use `nm`-style inspection for `luaopen_*` symbols.
- [ ] Register static modules through `package.preload` or equivalent C hooks.
- [ ] Keep link order user-controlled.
- [ ] Require dependent native libraries explicitly.

### Phase 14: Old-System Build Profiles

- [ ] Add `docs/OLD-SYSTEM-BUILD-PROFILES.md`.
- [ ] Document Windows XP-compatible toolchain profile.
- [ ] Specify Lua 5.5.0 and launcher build flags that avoid new Windows CRT
      dependency.
- [ ] Specify how `lua55.dll` is built and bundled for old Windows dynamic
      native support.
- [ ] Add a runtime profile checker.
- [ ] Require a real XP-profile smoke run before release notes claim XP support.

### Phase 15: Release Readiness

- [ ] Align README, README-zh, manpage, test docs, and rockspec.
- [ ] Document supported, experimental, and unsupported behavior.
- [ ] Run syntax checks.
- [ ] Run sample smoke tests.
- [ ] Run analyzer, trace, onedir, onefile, native fixture, and diagnostics.
- [ ] Build through LuaRocks.
- [ ] Verify same-environment guarantee on at least one Linux and one Windows
      profile.

## First Milestone

The first useful milestone is complete when:

- `luai -a test/student_management_system/main.lua` produces a dependency list.
- `luai -t test/native_module/main.lua` explains native module resolution.
- `luai -c --onedir test/native_module/main.lua -o dist/native-module`
  produces a directory bundle.
- The directory bundle runs without a separate Lua installation on the same
  build environment.
- Docs state the current Lua compatibility and same OS, architecture, ABI
  boundary.
- The rockspec installs `luai` and does not reference missing modules.

## Non-Goals For The First Milestone

- Cross-compiling from Linux to Windows or from modern Windows to Windows XP.
- Automatically discovering every external system library.
- Loading dynamic native modules directly from memory.
- Supporting arbitrary static native module link graphs.
- Producing a universal bundle that ignores Lua ABI and compiler-runtime
  differences.
- Claiming Windows XP compatibility without a real XP-profile build and smoke
  run.

## Baseline Verification Commands

```sh
lua -v
luac -p src/*.lua
lua test/smoke_all.lua
luarocks make luainstaller-1.0.0-1.rockspec
luai -a test/student_management_system/main.lua
luai -t test/native_module/main.lua
luai -c --onedir test/native_module/main.lua -o dist/native-module
dist/native-module/native-module
luai -c --onefile test/native_module/main.lua -o dist/native-module-onefile
dist/native-module-onefile
```

Adjust executable suffixes and paths per platform. On Windows, run generated
`.exe` files from a clean shell where Lua is not on `PATH`.

## References

- Lua 5.5 official documentation: `https://www.lua.org/manual/5.5/readme.html`
- Lua version history: `https://www.lua.org/versions.html`
- luastatic repository: `https://github.com/ers35/luastatic`
- Existing research note: `docs/IMPLEMENTATION-RESEARCH.md`
- Project coding style: `CODING-STYLE.txt`
