# Cross-Platform Onedir Demo Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `luai -c --onedir` build runnable clean-environment demo bundles on Linux, macOS, and Windows, including native Lua C module demos.

**Architecture:** Split the current Linux-only bundler behavior into a platform profile selected at runtime or by an explicit build profile. Keep analyzer, manifest, bootstrap generation, C launcher generation, and `.luai` layout shared. Add platform-specific compile flags, loader paths, runtime library handling, native extension names, and remote verification scripts incrementally.

**Tech Stack:** Lua 5.4-compatible project code, C launcher, Linux `cc/pkg-config/ldd`, macOS `cc/otool/install_name_tool`, Windows MinGW `x86_64-w64-mingw32-gcc`, PowerShell remote smoke scripts, `test/smoke_all.lua`.

---

## Scope Split

This plan executes the broad spec in verifiable slices:

1. Platform profile abstraction and regression tests.
2. macOS pure Lua `--onedir` bundle.
3. macOS native demo bundle support.
4. Windows pure Lua `--onedir` bundle through a `win64-mingw-lua54` profile.
5. Windows native demo bundle support.
6. Unified remote test matrix scripts and documentation.

Linux must stay green after every task.

## File Map

- Modify `src/bundler.lua`: delegate platform decisions to `luainstaller.platform`, keep shared bundle orchestration here.
- Create `src/platform.lua`: host detection, shell command helpers, output naming, native extension patterns, compile profile selection, runtime-library discovery.
- Modify `src/cgen.lua`: extend native `package.cpath` patterns for `.dylib` and `.dll`.
- Modify `luainstaller-1.0.0-1.rockspec`: install `luainstaller.platform`.
- Modify `test/smoke_all.lua`: add local platform profile and command construction coverage.
- Create `tools/remote-test-macos.sh`: build/source-install/test macOS bundles remotely.
- Create `tools/remote-test-windows.ps1`: run Windows bundle smoke tests with copied toolchain/runtime inputs.
- Create `tools/remote-test-linux.sh`: preserve Linux remote clean-runtime bundle verification.
- Update `docs/CROSS-PLATFORM-TEST-MATRIX.md`: replace diagnostic-only macOS/Windows entries with real bundle results as each platform lands.

## Task 1: Platform Profile Contract

**Files:**
- Create: `src/platform.lua`
- Modify: `test/smoke_all.lua`
- Modify: `luainstaller-1.0.0-1.rockspec`

- [ ] **Step 1: Add failing smoke coverage for platform profile basics**

Add this function in `test/smoke_all.lua` after `check_bundler_without_popen()`:

```lua
local function check_platform_profiles()
    local script = SOURCE_LOADER .. [[
local platform = require("luainstaller.platform")
local host = platform.detectHost()
assert(host.os == "linux" or host.os == "macos" or host.os == "windows" or host.os == "unknown")
assert(type(host.arch) == "string")

local linux = platform.profile({ target_os = "linux" })
assert(linux.executable_suffix == "")
assert(linux.native_extensions[1] == ".so")
assert(linux.loader_rpath == "$ORIGIN/.luai/native")

local macos = platform.profile({ target_os = "macos", lua_prefix = "/tmp/lua" })
assert(macos.executable_suffix == "")
assert(macos.native_extensions[1] == ".so")
assert(macos.native_extensions[2] == ".dylib")
assert(macos.loader_rpath == "@loader_path/.luai/native")
assert(macos.lua_prefix == "/tmp/lua")

local windows = platform.profile({ target_os = "windows" })
assert(windows.executable_suffix == ".exe")
assert(windows.native_extensions[1] == ".dll")
assert(windows.loader_rpath == nil)
print("platform profiles ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "platform profiles ok")
end
```

Call it before `check_cli_contract()`:

```lua
check_platform_profiles()
```

Add this preload line to `SOURCE_LOADER`:

```lua
package.preload["luainstaller.platform"] = function() return dofile("src/platform.lua") end
```

- [ ] **Step 2: Verify RED**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL because `src/platform.lua` does not exist.

- [ ] **Step 3: Implement `src/platform.lua`**

Create `src/platform.lua`:

```lua
--[[
Platform profile helpers for luainstaller.

Author:
    WaterRun
File:
    platform.lua
Date:
    2026-06-21
Updated:
    2026-06-21
]]

local M = {}

local PATH_SEP = package.config:sub(1, 1)

local function commandLine(command)
    if type(io.popen) ~= "function" then
        return nil
    end
    local ok, pipe = pcall(io.popen, command .. " 2>&1", "r")
    if not ok or not pipe then
        return nil
    end
    local output = pipe:read("*a") or ""
    pipe:close()
    return output
end

local function firstLine(value)
    return value and value:match("^[^\r\n]+") or nil
end

function M.detectHost()
    if PATH_SEP == "\\" then
        return { os = "windows", arch = os.getenv("PROCESSOR_ARCHITECTURE") or "unknown" }
    end
    local uname_s = firstLine(commandLine("uname -s"))
    local uname_m = firstLine(commandLine("uname -m"))
    local os_name = "unknown"
    if uname_s == "Linux" then
        os_name = "linux"
    elseif uname_s == "Darwin" then
        os_name = "macos"
    end
    return { os = os_name, arch = uname_m or "unknown" }
end

function M.profile(opts)
    opts = opts or {}
    local host = M.detectHost()
    local target_os = opts.target_os or host.os
    if target_os == "linux" then
        return {
            target_os = "linux",
            executable_suffix = "",
            native_extensions = { ".so" },
            loader_rpath = "$ORIGIN/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "macos" then
        return {
            target_os = "macos",
            executable_suffix = "",
            native_extensions = { ".so", ".dylib" },
            loader_rpath = "@loader_path/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "windows" then
        return {
            target_os = "windows",
            executable_suffix = ".exe",
            native_extensions = { ".dll" },
            loader_rpath = nil,
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    return {
        target_os = target_os,
        executable_suffix = "",
        native_extensions = { ".so" },
        loader_rpath = nil,
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    }
end

return M
```

- [ ] **Step 4: Install module in rockspec**

Add to `luainstaller-1.0.0-1.rockspec` modules:

```lua
["luainstaller.platform"] = "src/platform.lua",
```

- [ ] **Step 5: Verify GREEN**

Run:

```sh
luac -p src/*.lua test/smoke_all.lua
lua test/smoke_all.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add src/platform.lua test/smoke_all.lua luainstaller-1.0.0-1.rockspec
git commit -m "feat: add platform profile helpers"
```

## Task 2: Shared Bundler Uses Platform Profile

**Files:**
- Modify: `src/bundler.lua`
- Modify: `test/smoke_all.lua`

- [ ] **Step 1: Add failing test for macOS profile command construction**

Add a test helper in `test/smoke_all.lua`:

```lua
local function check_macos_profile_reaches_toolchain()
    local script = SOURCE_LOADER .. [[
local bundler = require("luainstaller.bundler")
local result = bundler.bundleOnedir({
    entry = "test/runtime_bundle/main.lua",
    out = "/tmp/luainstaller-macos-profile-smoke",
    target_os = "macos",
    lua_prefix = "/tmp/luainstaller-missing-lua-prefix",
    dependencies = { scripts = {}, libraries = {} },
    trace = {},
    manifest = {
        version = 1,
        launcher = { profile = "shared-lua" },
        modules = { lua = {}, native = {}, external = {} },
    },
})
assert(result.ok == false)
assert(result.error.type == "ToolchainError")
assert(tostring(result.error.message):find("Lua prefix", 1, true))
print("macos profile toolchain ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "macos profile toolchain ok")
end
```

Call it before Linux onedir bundle tests.

- [ ] **Step 2: Verify RED**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL because `bundleOnedir()` still rejects non-Linux before checking
the macOS profile.

- [ ] **Step 3: Update `src/bundler.lua` to select platform profile**

At the top:

```lua
local platform = require("luainstaller.platform")
```

Inside `bundleOnedir(opts)`, replace the current Linux-only host checks with:

```lua
    local profile = platform.profile({
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    if profile.target_os == "windows" then
        return makeError("UnsupportedPlatformError", "windows onedir bundling is not implemented yet")
    end
    if profile.target_os ~= "linux" and profile.target_os ~= "macos" then
        return makeError("UnsupportedPlatformError", "unsupported onedir target: " .. tostring(profile.target_os))
    end
```

Keep the existing `io.popen` guard.

- [ ] **Step 4: Add macOS Lua prefix validation helper**

Add:

```lua
local function validateLuaPrefix(prefix)
    if type(prefix) ~= "string" or prefix == "" then
        return makeError("ToolchainError", "Lua prefix is required for this onedir target")
    end
    local include = normalizePath(prefix .. "/include/lua.h")
    local liblua = normalizePath(prefix .. "/lib/liblua.a")
    if not fileExists(include) or not fileExists(liblua) then
        return makeError("ToolchainError", "Lua prefix must contain include/lua.h and lib/liblua.a", {
            lua_prefix = prefix,
        })
    end
    return nil
end
```

Add `fileExists(path)` using `io.open(path, "rb")`.

- [ ] **Step 5: Verify GREEN**

Run:

```sh
lua test/smoke_all.lua
```

Expected: PASS, with Linux behavior unchanged.

- [ ] **Step 6: Commit**

```sh
git add src/bundler.lua test/smoke_all.lua
git commit -m "feat: route onedir through platform profiles"
```

## Task 3: macOS Pure Lua Onedir Bundle

**Files:**
- Modify: `src/bundler.lua`
- Modify: `src/cgen.lua`
- Create: `tools/remote-test-macos.sh`

- [ ] **Step 1: Add remote macOS pure Lua smoke script**

Create `tools/remote-test-macos.sh`:

```sh
#!/bin/sh
set -eu

BASTION=${BASTION:-"waterrun@192.168.10.40"}
MAC_HOST=${MAC_HOST:-"yymac06"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-mac-current"}
LUA_PREFIX=${LUA_PREFIX:-"/tmp/luainstaller-mac-lua-posix"}
PREFIX=${PREFIX:-"/tmp/luainstaller-mac-prefix"}
BUNDLE=${BUNDLE:-"/tmp/luainstaller-mac-runtime"}

tar --exclude=.git -C "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" -cf - . \
  | ssh "$BASTION" "ssh $MAC_HOST 'rm -rf \"$REMOTE_ROOT\" && mkdir -p \"$REMOTE_ROOT\" && tar -xf - -C \"$REMOTE_ROOT\"'"

ssh "$BASTION" "ssh $MAC_HOST 'set -e
cd \"$REMOTE_ROOT\"
sh tools/install-source.sh --lua \"$LUA_PREFIX/bin/lua\" --prefix \"$PREFIX\"
rm -rf \"$BUNDLE\"
LUAI_LUA_PREFIX=\"$LUA_PREFIX\" \"$PREFIX/bin/luai\" -c --onedir test/runtime_bundle/main.lua -o \"$BUNDLE\" --max-deps 120
env -i PATH=/usr/bin:/bin \"$BUNDLE/runtime\" macos-clean | grep \"hello macos-clean\"
'"
```

Make it executable.

- [ ] **Step 2: Verify RED**

Run:

```sh
sh tools/remote-test-macos.sh
```

Expected: FAIL because macOS compile/link is not implemented.

- [ ] **Step 3: Add macOS compile flags**

In `src/bundler.lua`, when `profile.target_os == "macos"`:

```lua
local compile_cmd = table.concat({
    "cc",
    shellQuote(c_path),
    "-I" .. shellQuote(profile.lua_prefix .. "/include"),
    "-o",
    shellQuote(exe_path),
    "-Wl,-rpath," .. shellQuote("@loader_path/.luai/native"),
    shellQuote(profile.lua_prefix .. "/lib/liblua.a"),
    "-lm",
}, " ")
```

Skip `copyLuaRuntime()` for static `liblua.a`; set:

```lua
manifest.launcher.lua_runtime = {
    source_path = normalizePath(profile.lua_prefix .. "/lib/liblua.a"),
    destination_path = nil,
    link_mode = "static",
}
```

- [ ] **Step 4: Add macOS native cpath patterns**

In `src/cgen.lua`, ensure generated bootstrap prepends all of:

```lua
base .. "/?.so"
base .. "/?/init.so"
base .. "/?.dylib"
base .. "/?/init.dylib"
base .. "/?.dll"
base .. "/?/init.dll"
```

- [ ] **Step 5: Verify macOS GREEN and Linux regression**

Run:

```sh
sh tools/remote-test-macos.sh
lua test/smoke_all.lua
```

Expected: macOS pure Lua bundle prints `hello macos-clean`; local Linux smoke
still passes.

- [ ] **Step 6: Commit**

```sh
git add src/bundler.lua src/cgen.lua tools/remote-test-macos.sh
git commit -m "feat: add macos onedir pure lua bundle"
```

## Task 4: macOS Native Demo Increment

**Files:**
- Modify: `tools/remote-test-macos.sh`
- Modify: `docs/CROSS-PLATFORM-TEST-MATRIX.md`

- [ ] **Step 1: Extend remote script to build native modules into the Lua prefix**

Add functions that build `lua-cjson`, `luafilesystem`, `lsqlite3`, and
`luasocket` from source into `$LUA_PREFIX/lib/lua/5.4`.

Use each module's upstream source tarball URL in the script and compile with:

```sh
cc -bundle -undefined dynamic_lookup -I"$LUA_PREFIX/include" module.c -o "$LUA_PREFIX/lib/lua/5.4/module.dylib"
```

For nested modules, write paths such as:

```sh
mkdir -p "$LUA_PREFIX/lib/lua/5.4/socket"
cc -bundle -undefined dynamic_lookup -I"$LUA_PREFIX/include" luasocket/src/*.c -o "$LUA_PREFIX/lib/lua/5.4/socket/core.so"
```

- [ ] **Step 2: Add one native demo at a time to the remote script**

Append these checks after the pure Lua check:

```sh
LUAI_LUA_PREFIX="$LUA_PREFIX" "$PREFIX/bin/luai" -c --onedir test/student_management_system/main.lua -o /tmp/luainstaller-mac-student --max-deps 250
env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-student/student --data /tmp/macos-students.json seed | grep "Seeded 8 students"

LUAI_LUA_PREFIX="$LUA_PREFIX" "$PREFIX/bin/luai" -c --onedir test/ltokei/main.lua -o /tmp/luainstaller-mac-ltokei --max-deps 250
env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-ltokei/ltokei /tmp/luainstaller-mac-ltokei/.luai | grep "Total"
```

Add `savinglua` and `firebird_web_sql` only after `cjson`, `lfs`, `lsqlite3`,
and `socket.core` are confirmed loadable from the temporary prefix.

- [ ] **Step 3: Verify and commit**

Run:

```sh
sh tools/remote-test-macos.sh
```

Expected: each enabled macOS demo runs from its bundle with `LUA_PATH` and
`LUA_CPATH` absent.

Commit:

```sh
git add tools/remote-test-macos.sh docs/CROSS-PLATFORM-TEST-MATRIX.md
git commit -m "test: verify macos native demo bundles"
```

## Task 5: Windows Pure Lua Profile

**Files:**
- Modify: `src/platform.lua`
- Modify: `src/bundler.lua`
- Create: `tools/remote-test-windows.ps1`
- Create: `tools/build-windows-lua54.sh`

- [ ] **Step 1: Add Windows profile script**

Create `tools/build-windows-lua54.sh` to build `/tmp/luainstaller-win-lua` with
`x86_64-w64-mingw32-gcc` and produce `lua.exe`, `lua54.dll`, `liblua.a`, and
headers.

- [ ] **Step 2: Add Windows remote test script**

Create `tools/remote-test-windows.ps1` that:

```powershell
$ErrorActionPreference = 'Stop'
$tmp = $env:TEMP
$env:LUA_PATH = 'src/?.lua;src/?/init.lua;;'
& $lua src\cli.lua -c --onedir test\runtime_bundle\main.lua -o "$tmp\luainstaller-win-runtime" --max-deps 120
Remove-Item Env:\LUA_PATH -ErrorAction SilentlyContinue
Remove-Item Env:\LUA_CPATH -ErrorAction SilentlyContinue
& "$tmp\luainstaller-win-runtime\runtime.exe" windows-clean
```

- [ ] **Step 3: Implement Windows compile profile**

In `src/bundler.lua`, allow `target_os = "windows"` when
`opts.target_profile == "win64-mingw-lua54"`. Compile with:

```sh
x86_64-w64-mingw32-gcc launcher.c -I<lua-prefix>/include -L<lua-prefix>/lib -llua -lm -o runtime.exe
```

Copy `lua54.dll` beside the executable and into `.luai/native`.

- [ ] **Step 4: Verify and commit**

Run the Windows remote smoke through SSH and PowerShell.

Commit:

```sh
git add src/platform.lua src/bundler.lua tools/build-windows-lua54.sh tools/remote-test-windows.ps1
git commit -m "feat: add windows pure lua onedir profile"
```

## Task 6: Windows Native Demo Increment

**Files:**
- Modify: `tools/build-windows-lua54.sh`
- Modify: `tools/remote-test-windows.ps1`
- Modify: `docs/CROSS-PLATFORM-TEST-MATRIX.md`

- [ ] **Step 1: Build Windows native modules with MinGW**

Extend `tools/build-windows-lua54.sh` to build `cjson.dll`, `lfs.dll`,
`lsqlite3.dll`, and `socket/core.dll` against the same Lua DLL import library.

- [ ] **Step 2: Add native demo bundle checks to PowerShell**

Run student, ltokei, savinglua, and firebird status endpoint from copied bundle
directories with `LUA_PATH` and `LUA_CPATH` removed.

- [ ] **Step 3: Verify and commit**

Run:

```sh
powershell -File tools/remote-test-windows.ps1
```

Expected: all selected Windows demo bundles run on `192.168.69.130`.

Commit:

```sh
git add tools/build-windows-lua54.sh tools/remote-test-windows.ps1 docs/CROSS-PLATFORM-TEST-MATRIX.md
git commit -m "test: verify windows native demo bundles"
```

## Task 7: Final Matrix And Documentation

**Files:**
- Modify: `docs/CROSS-PLATFORM-TEST-MATRIX.md`
- Modify: `README.md`
- Modify: `README-zh.md`
- Modify: `luainstaller.1`

- [ ] **Step 1: Run final verification commands**

Run:

```sh
luac -p src/*.lua test/smoke_all.lua
sh -n tools/install-source.sh
lua test/smoke_all.lua
luarocks make --tree /tmp/luainstaller-rocktree luainstaller-1.0.0-1.rockspec
sh tools/remote-test-linux.sh
sh tools/remote-test-macos.sh
powershell -File tools/remote-test-windows.ps1
```

- [ ] **Step 2: Update docs with exact results**

Record all platform hostnames, architectures, Lua profile paths, clean runtime
commands, and demo pass/fail status in `docs/CROSS-PLATFORM-TEST-MATRIX.md`.

- [ ] **Step 3: Commit and push**

```sh
git add docs/CROSS-PLATFORM-TEST-MATRIX.md README.md README-zh.md luainstaller.1
git commit -m "docs: record completed cross-platform demo matrix"
git push
```
