# Cross-Platform Test Matrix

Date: 2026-06-21

This document records the current Linux, macOS, and Windows verification loop
for branch `codex/linux-onedir-demo-validation`.

## Current Support Boundary

`luainstaller` currently implements dependency analysis on any host with a
compatible Lua runtime and Linux `--onedir` bundle output on Linux hosts with a
working local C/Lua toolchain.

macOS and Windows bundle output are intentionally rejected with
`UnsupportedPlatformError` in this stage. They are still useful test targets for
source installation, CLI parsing, analyzer behavior, and clear unsupported
platform diagnostics.

## Environment Results

| Host | OS / Arch | LuaRocks | Result |
| --- | --- | --- | --- |
| local workstation | Linux x86_64 | available | Full smoke, LuaRocks install, source install, and no-system-`lua` container bundle runtime passed. |
| `192.168.10.40` | Linux x86_64 | available | Full smoke passed after installing sample native modules. Source-installed `luai` built and ran a pure Lua bundle. |
| `192.168.5.19` | Linux aarch64 | unavailable | Source install and `luai -a` passed. `luai -c --onedir` cleanly failed with `ToolchainError` because Lua headers / Lua `pkg-config` metadata are not installed. |
| `yymac06` | macOS arm64 | unavailable | Temporary user-local Lua 5.4.8 was built. Source install and `luai -a` passed. `luai -c --onedir` cleanly failed with `UnsupportedPlatformError`. |
| `192.168.69.130` | Windows 10 x64 | unavailable | Temporary cross-compiled Lua 5.4.8 was copied in. Source-tree CLI syntax, `--version`, and `-a` passed. `-c --onedir` cleanly failed with `UnsupportedPlatformError`. |

## Fixes From This Loop

- `luainstaller.manifest` no longer crashes when `io.popen` is unavailable.
  Platform fields degrade to strings such as `unknown`.
- `luainstaller.bundler` now checks for `io.popen` before using filesystem or
  toolchain shell commands and returns `ToolchainError` when the runtime cannot
  execute commands.
- `luainstaller.bundler` now rejects non-Linux POSIX hosts before attempting the
  Linux filesystem/toolchain flow.
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

macOS with a user-local Lua:

```sh
sh tools/install-source.sh --lua /tmp/luainstaller-mac-lua-posix/bin/lua --prefix /tmp/luainstaller-mac-prefix
/tmp/luainstaller-mac-prefix/bin/luai --version
/tmp/luainstaller-mac-prefix/bin/luai -a /tmp/luainstaller-mac-current/test/runtime_bundle/main.lua --max-deps 120
/tmp/luainstaller-mac-prefix/bin/luai -c --onedir /tmp/luainstaller-mac-current/test/runtime_bundle/main.lua -o /tmp/luainstaller-mac-runtime --max-deps 120
```

The final macOS command must fail with `UnsupportedPlatformError` until macOS
bundle output is implemented.

Windows with a temporary Lua:

```powershell
$env:LUA_PATH = 'src/?.lua;src/?/init.lua;;'
& $lua src\cli.lua --version
& $lua src\cli.lua -a test\runtime_bundle\main.lua --max-deps 120
& $lua src\cli.lua -c --onedir test\runtime_bundle\main.lua -o $env:TEMP\luainstaller-win-runtime --max-deps 120
```

The final Windows command must fail with `UnsupportedPlatformError` until
Windows bundle output is implemented.

## Remaining Work

- Implement macOS bundle output with `@loader_path`, `.dylib` install-name
  handling, and a macOS launcher build path.
- Implement Windows bundle output with `.exe` launcher generation, `lua*.dll`
  placement, companion DLL discovery, and Windows path handling.
- Add a native Windows source installer or package installer once a supported
  Windows runtime/toolchain profile is selected.
- Add CI or lab automation that can rerun this matrix without manually copying
  temporary Lua runtimes.
