# Cross-Platform Test Matrix

Date: 2026-06-22

This document records the current Linux, macOS, and Windows verification loop
for the `main` branch.

## Current Support Boundary

`luainstaller` currently implements dependency analysis on any host with a
compatible Lua runtime, Linux `--onedir` and `--onefile` bundle output on Linux
hosts with a working local C/Lua toolchain, and macOS `--onedir` and `--onefile`
bundle output on macOS hosts when a matching static Lua prefix is supplied.
Windows `--onedir` and `--onefile` bundle output is implemented as a profiled
build from Linux using MinGW and a Windows Lua prefix.

The tested runtime promise is still same OS family, same architecture, same Lua
ABI, and compatible native module DLLs. General cross-building and automatic
external dependency closure remain outside this stage.

## Environment Results

| Host | OS / Arch | LuaRocks | Result |
| --- | --- | --- | --- |
| local workstation | Linux x86_64 | available | Full smoke, LuaRocks install, source install, and no-system-`lua` container bundle runtime passed. |
| `192.168.10.40` | Linux x86_64 | available | Full smoke passed after installing sample native modules. Source-installed `luai` built and ran a pure Lua bundle. |
| `192.168.5.19` | Linux aarch64 | unavailable | Source install and `luai -a` passed. `luai -c --onedir` cleanly failed with `ToolchainError` because Lua headers / Lua `pkg-config` metadata are not installed. |
| `yymac06` | macOS arm64 | temporary `/tmp` LuaRocks plus local SQLite source cache | Temporary user-local Lua 5.4.8 and LuaRocks were built. Pure Lua, `student_management_system`, `savinglua`, `ltokei`, and `firebird_web_sql` `--onedir` bundles build and run from clean `env -i` runtimes. Pure Lua and `student_management_system` `--onefile` bundles also build and run from clean runtimes. |
| `192.168.69.130` | Windows 10 x64 | unavailable on target | Linux-built Windows Lua 5.4.8, MinGW-built native DLLs, and bundled pure Lua dependencies were used to build pure Lua, `student_management_system`, `savinglua`, `ltokei`, and `firebird_web_sql` `--onedir` bundles plus pure Lua and `student_management_system` `--onefile` bundles. The bundles run on the Windows host from a cleaned PowerShell environment without installed Lua or LuaRocks. |

## Fixes From This Loop

- `luainstaller.manifest` no longer crashes when `io.popen` is unavailable.
  Platform fields degrade to strings such as `unknown`.
- `luainstaller.bundler` now checks for `io.popen` before using filesystem or
  toolchain shell commands and returns `ToolchainError` when the runtime cannot
  execute commands.
- `luainstaller.bundler` now rejects non-Linux POSIX hosts before attempting the
  Linux filesystem/toolchain flow.
- `luainstaller.bundler` now supports `--target-os windows` from Linux with
  MinGW, copies `lua54.dll` beside the launcher and into `.luai/native/`, and
  preserves Windows native module paths such as `socket/core.dll`.
- `test/smoke_all.lua` covers the no-`io.popen` manifest and bundler contracts.

## Reproduction Commands

Local Linux:

```sh
luac -p src/*.lua test/smoke_all.lua
sh -n tools/install-source.sh
lua test/smoke_all.lua
luarocks make --tree /tmp/luainstaller-rocktree luainstaller-1.0.0-1.rockspec
```

Linux without LuaRocks:

```sh
sh tools/install-source.sh --prefix /tmp/luainstaller-source-prefix
/tmp/luainstaller-source-prefix/bin/luai --version
/tmp/luainstaller-source-prefix/bin/luai -a test/runtime_bundle/main.lua --max-deps 120
```

Remote Linux hosts:

```sh
sh tools/remote-test-linux.sh
```

The script copies the current checkout to `192.168.10.40` and `192.168.5.19`.
The x86_64 host runs the full smoke suite plus a source-installed pure Lua
bundle from `env -i`. The aarch64 host verifies source install and analysis in a
LuaRocks-unavailable environment, then accepts either a runnable bundle or the
expected `ToolchainError` when Lua headers / `pkg-config` metadata are absent.

macOS with a user-local Lua:

```sh
sh tools/remote-test-macos.sh
```

The script builds or reuses temporary user-local Lua and LuaRocks under `/tmp`,
source-installs `luai`, builds the pure Lua, `student_management_system`,
`savinglua`, `ltokei`, and `firebird_web_sql` demos as `--onedir` bundles,
builds pure Lua and `student_management_system` as `--onefile` bundles, and runs
the resulting executables under `env -i PATH=/usr/bin:/bin`.

For `savinglua`, the script does not rely on the host `/usr/lib/libsqlite3.dylib`
or on LuaRocks being able to build a working `lsqlite3` module. It downloads
`lsqlite3_v096.zip` and SQLite amalgamation `sqlite-amalgamation-3530200.zip`
into a local cache, copies them through the bastion host, and compiles
`lsqlite3.so` on macOS with the SQLite amalgamation included in the module.
That keeps the packaged demo independent from the target machine's SQLite
runtime symbol exports.

Windows with MinGW-built Lua and native DLLs:

```sh
WINDOWS_PASSWORD=... sh tools/remote-test-windows.sh
```

The script builds Lua 5.4.8 for Windows with MinGW, cross-compiles `cjson`,
`lfs`, `lsqlite3`, `socket.core`, and `mime.core` DLLs, copies Pegasus,
LuaSocket Lua modules, and `mimetypes`, then builds and verifies all selected
Windows `--onedir` bundles plus pure Lua and `student_management_system`
`--onefile` bundles under Wine and on `192.168.69.130`.
Set `SSH_OPTS` to override the default lab automation SSH options.

## Remaining Work

- Add a native Windows source installer or package installer for users who want
  to run the CLI directly on Windows instead of cross-building from Linux.
- Add general external DLL dependency closure for native modules beyond the
  explicitly built test set.
