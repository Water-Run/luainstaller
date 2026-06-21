# Cross-Platform Onedir Demo Validation Design

Date: 2026-06-21

## Purpose

Complete the remote test and fix loop for Linux, macOS, and Windows so packaged
demo programs run in clean runtime environments. The target is not just clear
diagnostics. The target is real `--onedir` bundle output on all three platform
families for the repository demos, including demos that depend on native Lua C
modules.

## Current State

Linux `--onedir` exists and has passed local and remote validation. The Linux
bundle copies the linked Lua shared runtime into `.luai/native`, copies detected
native Lua C modules, links the launcher with `$ORIGIN/.luai/native`, and has
been run in a container without a system `lua` command.

macOS and Windows currently run the CLI and analyzer, but `luai -c --onedir`
returns `UnsupportedPlatformError`. That is a useful diagnostic state, but it
does not satisfy this goal.

## Required End State

Each platform must satisfy the same observable contract:

1. Build all selected demos with `luai -c --onedir`.
2. Copy the resulting bundle directories to a clean runtime location.
3. Run the packaged executables with no dependency on a system `lua` command or
   project source tree.
4. Verify pure Lua and native Lua C module demos.
5. Record failures as reproducible test output, not as manual notes.

The selected demo set is:

- `test/runtime_bundle/main.lua` - pure Lua baseline.
- `test/student_management_system/main.lua` - native `cjson`.
- `test/ltokei/main.lua` - native `lfs`.
- `test/savinglua/main.lua` - native `cjson` and `lsqlite3`.
- `test/firebird_web_sql/server.lua` - Pegasus, `socket.core`, `cjson`, and
  optional Firebird/LuaSQL support.

Optional modules detected through `pcall(require, ...)` remain optional. The
Firebird database driver does not have to be present for the web demo to pass
the status endpoint smoke test.

## Platform Strategy

The bundler should keep one public API, `luainstaller.bundle({ mode = "onedir" })`,
but move platform-specific decisions into a small platform layer selected at
runtime.

### Shared Flow

All platforms use the same analyzer, trace, manifest, bootstrap generation, C
launcher source generation, `.luai/manifest.lua`, and `.luai/native` layout.
The platform layer owns:

- executable suffix;
- shell quoting and file operations where they differ;
- launcher compile flags;
- runtime library discovery;
- runtime library copy destination;
- dynamic loader search path;
- clean-environment validation command.

### Linux

Linux keeps the existing behavior:

- executable has no required suffix;
- launcher is compiled with local `cc` and `pkg-config --cflags --libs lua`;
- loader path uses `$ORIGIN/.luai/native`;
- linked Lua shared runtime is discovered through `ldd`;
- native module dependencies remain same-ABI and same-system-family.

### macOS

macOS `--onedir` should be added next because the remote macOS host has `cc`,
`otool`, `install_name_tool`, `curl`, and `git`, and a user-local Lua 5.4.8 can
be built without changing system state.

The macOS bundle should:

- compile the same generated launcher with local `cc`;
- use Lua compile/link flags from a user-local Lua build or explicit
  `LUAI_LUA_PREFIX`;
- link with `-Wl,-rpath,@loader_path/.luai/native`;
- discover the linked Lua `.dylib` with `otool -L`;
- copy that `.dylib` into `.luai/native`;
- use `install_name_tool` when needed so the executable resolves Lua from
  `@rpath` / `@loader_path/.luai/native`;
- prepend `.luai/native/?.so`, `.luai/native/?/init.so`,
  `.luai/native/?.dylib`, and `.luai/native/?/init.dylib` to `package.cpath`.

For the first macOS implementation, the target runtime compatibility is same
macOS family, same architecture, same Lua ABI, and compatible native module
builds.

### Windows

Windows `--onedir` needs an `.exe` launcher and a Lua DLL in the bundle. The
current Windows remote host has PowerShell, curl, and tar but no Lua, Git, or
native compiler in PATH. The local Linux host has MinGW cross-compilers, so the
first Windows path should be an explicit Windows-profile build driven from Linux
and executed remotely on Windows.

The Windows bundle should:

- generate a Windows `.exe` launcher;
- compile with `x86_64-w64-mingw32-gcc` for the current Windows x64 target;
- link against a known Lua DLL/import library built for the same profile;
- copy `lua54.dll` or the selected Lua DLL beside the launcher or into
  `.luai/native` with a loader path that Windows will search;
- copy native Lua C modules as `.dll` files, preserving module-name paths for
  nested modules such as `socket.core`;
- run on the Windows host without installed Lua or LuaRocks.

The first Windows implementation can use a test profile named `win64-mingw-lua54`.
Future work can add Lua 5.5 and Windows XP-compatible profiles.

## Native Module Strategy

The demos require platform-native C modules. LuaRocks is not available on every
remote host, so the validation loop must not depend on system-wide LuaRocks.

The test harness should prepare a temporary per-platform dependency root:

- Linux x86_64 may use the existing user LuaRocks tree for native modules, but
  clean runtime verification must still run without system `lua`.
- Linux aarch64 must either install Lua headers / pkg-config metadata in a
  temporary toolchain root or report the missing development package as an
  environment setup failure before claiming completion.
- macOS should build Lua and native modules into a temporary prefix owned by the
  test run.
- Windows should use MinGW-built Lua and MinGW-built native modules copied to
  the Windows host.

For this milestone, native module builds only need to cover the modules used by
the selected demos: `cjson`, `lfs`, `lsqlite3`, `socket.core`, and their direct
runtime companions.

## Clean Environment Definition

A clean runtime test means:

- the packaged executable is run from a copied bundle directory;
- `LUA_PATH` and `LUA_CPATH` are unset or set to empty values;
- the system `lua` command is absent or not used;
- project source paths are not readable through the runtime working directory;
- native modules are loaded from the bundle when they are part of the demo;
- platform system libraries may still be used when they are part of the same
  OS/ABI compatibility promise, unless explicitly copied as companion libraries.

## Remote Verification Harness

Add repeatable scripts under `tools/` so the matrix is not reconstructed from
chat logs:

- `tools/remote-test-linux.sh`
- `tools/remote-test-macos.sh`
- `tools/remote-test-windows.ps1`
- optionally a wrapper such as `tools/remote-test-matrix.sh`

Each script should print:

- host identity and OS/architecture;
- Lua/toolchain paths used for build;
- bundle output paths;
- runtime environment cleanup applied before execution;
- pass/fail status for each demo.

## Test Plan

Implementation should be TDD-driven:

1. Add local unit/smoke coverage for platform selection and platform-specific
   compile/link command construction.
2. Add a macOS remote smoke that fails while `--onedir` is unsupported.
3. Implement macOS pure Lua bundle until the remote pure Lua smoke passes.
4. Add macOS native-module demo smokes one module family at a time.
5. Add Windows profile tests that fail while `--onedir` is unsupported.
6. Implement Windows pure Lua bundle with MinGW until the Windows remote pure
   Lua smoke passes.
7. Add Windows native-module demo smokes one module family at a time.
8. Keep Linux regression checks green throughout.

## Non-Goals

- `--onefile` packaging.
- Cross-building macOS bundles from Linux.
- Claiming Windows XP compatibility.
- Automatic closure of every transitive native shared library.
- Static Lua or static native module linking.

## Acceptance Criteria

The goal is complete only when current evidence proves:

- Linux remote clean-runtime test passes for all selected demos.
- macOS remote clean-runtime test passes for all selected demos.
- Windows remote clean-runtime test passes for all selected demos.
- `lua test/smoke_all.lua` passes locally.
- LuaRocks install verification passes locally.
- Documentation records exact platform setup and remaining explicit limitations.
- The branch is pushed.
