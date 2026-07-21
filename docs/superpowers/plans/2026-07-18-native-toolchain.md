# Native Toolchain and Clean-target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every accepted native toolchain produce a relocatable artifact that loads a real Lua C module on its documented target profile.

**Architecture:** Constrain library candidates before probing, make loader inspection use the probe environment, and validate the staged distribution with an ordinary C module before publication. Linux uses shared liblua, macOS uses static liblua, and Windows 1.0 uses x86_64 DLLs with explicit CRT closure.

**Tech Stack:** Lua 5.1-5.5 C API, POSIX cc/ldd/otool, MSVC/dumpbin, existing platform/toolchain/bundler modules.

## Global Constraints

- Native-only build; no cross compilation.
- Linux accepts matching shared liblua only.
- macOS accepts matching static `liblua.a` only.
- Windows 1.0 accepts x86_64 only and must run without a preinstalled VC Redistributable.
- Explicit prefixes are authoritative and may use `lib`, `lib64`, safe symlinks, or versioned shared files.
- Accepted artifacts must load an ordinary C module after the source prefix is hidden.
- Physical hosts use owned temporary roots and no system mutation.

---

### Task 1: Enforce platform runtime profiles

**Files:**
- Create: `src/native_profile.lua`
- Modify: `src/toolchain.lua:244-289,609-680`
- Modify: `src/platform.lua:63-114`
- Modify: `src/cli.lua:55-115`
- Modify: `test/support/harness.lua:43-65`
- Modify: `luainstaller-1.0.0-1.rockspec:43-67`
- Modify: `test/version_contract.lua:85-110`
- Modify: `test/toolchain_native.lua:1-60`
- Modify: `test/production_edges.lua:396-430,2240-2310`
- Modify: `docs/PLATFORMS-NATIVE-LIMITS.adoc:37-68`

**Interfaces:**
- Produces: `native_profile.acceptsLibrary(profile, path) -> boolean, reason`.
- Consumes: platform profile `launcher_profile` and host architecture.
- Produces: `UnsupportedPlatformError` for Windows architectures other than x86_64.

- [ ] **Step 1: Add profile rejection regressions**

Use the test harness to simulate each profile and assert the candidate filter:

```lua
local native_profile = require("luainstaller.native_profile")
assert(native_profile.acceptsLibrary({ target_os = "linux" }, "/x/liblua.so"))
assert(not native_profile.acceptsLibrary({ target_os = "linux" }, "/x/liblua.a"))
assert(native_profile.acceptsLibrary({ target_os = "macos" }, "/x/liblua.a"))
assert(not native_profile.acceptsLibrary({ target_os = "macos" }, "/x/liblua.dylib"))
assert(native_profile.acceptsLibrary({ target_os = "windows" }, "C:/x/lua54.dll"))
```

Add platform assertions that Windows x86 and ARM64 profiles return
`UnsupportedPlatformError` while x86_64 succeeds.

- [ ] **Step 2: Run the profile regressions and observe RED**

Run: `lua test/production_edges.lua`

Expected: static Linux and shared macOS candidates are currently accepted, and
Windows ARM64 currently receives a profile.

- [ ] **Step 3: Implement the candidate filter**

```lua
local M = {}

function M.acceptsLibrary(profile, candidate)
    local lower = tostring(candidate):lower()
    if profile.target_os == "linux" then
        return lower:match("%.so[%d%.]*$") ~= nil,
            "Linux requires a shared liblua"
    elseif profile.target_os == "macos" then
        return lower:match("%.a$") ~= nil,
            "macOS requires static liblua.a"
    elseif profile.target_os == "windows" then
        return lower:match("%.dll$") ~= nil or lower:match("%.lib$") ~= nil,
            "Windows requires a Lua DLL/import library"
    end
    return false, "unsupported native runtime profile"
end

return M
```

Save this implementation as `src/native_profile.lua` and add it to the CLI
checkout loader, test harness, rockspec, and version contract. Filter
`prefixCandidate`, pkg-config, and LuaRocks candidates with it before compile
probing. Remove the generic static fallback from `verifyCandidate`. Restrict
the Windows platform profile to normalized `x86_64`.

- [ ] **Step 4: Update native contract tests**

Replace the current `link_mode == "static" or shared` assertion with:

```lua
if config.host.os == "linux" then
    assert(config.link_mode == "shared")
elseif config.host.os == "macos" then
    assert(config.link_mode == "static")
elseif config.host.os == "windows" then
    assert(config.link_mode == "shared")
end
```

- [ ] **Step 5: Run focused tests**

Run: `lua test/production_edges.lua && lua test/toolchain_native.lua`

Expected: profile regressions PASS. On a host with only static liblua,
`toolchain_native` fails with the new explicit Linux shared-runtime message;
Task 2 supplies the matrix shared library.

- [ ] **Step 6: Commit profile enforcement**

```bash
git add src/native_profile.lua src/toolchain.lua src/platform.lua src/cli.lua \
  test/support/harness.lua test/version_contract.lua test/toolchain_native.lua \
  test/production_edges.lua luainstaller-1.0.0-1.rockspec \
  docs/PLATFORMS-NATIVE-LIMITS.adoc
git commit -m "fix: enforce native runtime profiles"
```

### Task 2: Build shared Linux matrix runtimes

**Files:**
- Modify: `tools/test-lua-versions.sh:90-121`
- Modify: `tools/remote-test-linux.sh:180-230`
- Modify: `test/version_contract.lua:1-130`

**Interfaces:**
- Produces: `$prefix/lib/liblua.so.<abi>` and relative symlinks
  `liblua.so.<major>` and `liblua.so` for each official Linux Lua build.
- Consumed by: `toolchain.resolve` and native bundle tests.

- [ ] **Step 1: Add matrix assertions for shared runtime identity**

```sh
test -f "$prefix/lib/liblua.so.$abi"
test -L "$prefix/lib/liblua.so"
test "$(readlink "$prefix/lib/liblua.so")" = "liblua.so.$abi"
```

Run the current matrix and observe RED because official Lua's default install
contains only `liblua.a`.

- [ ] **Step 2: Build PIC objects and the shared library**

After the official Lua build, rebuild its objects with `-fPIC`, then link and
install the runtime:

```sh
make clean
make "MYCFLAGS=-fPIC $lua_cflags" linux
make INSTALL_TOP="$prefix" install
abi=${version%.*}
cc -shared -Wl,-soname,"liblua.so.$abi" -o "$prefix/lib/liblua.so.$abi" \
    src/lapi.o src/lcode.o src/lctype.o src/ldebug.o src/ldo.o src/ldump.o \
    src/lfunc.o src/lgc.o src/llex.o src/lmem.o src/lobject.o src/lopcodes.o \
    src/lparser.o src/lstate.o src/lstring.o src/ltable.o src/ltm.o \
    src/lundump.o src/lvm.o src/lzio.o src/lauxlib.o src/lbaselib.o \
    src/lcorolib.o src/ldblib.o src/liolib.o src/lmathlib.o src/loadlib.o \
    src/loslib.o src/lstrlib.o src/ltablib.o src/lutf8lib.o src/linit.o \
    -lm -ldl
ln -s "liblua.so.$abi" "$prefix/lib/liblua.so"
```

Account for version-specific object sets by deriving the object list from the
created archive rather than assuming `lutf8lib.o` exists on Lua 5.1/5.2:

```sh
objects=$(ar t src/liblua.a | sed "s#^#src/#")
# Intentional archive-member splitting; reject whitespace/control bytes first.
cc -shared -Wl,-soname,"liblua.so.$abi" -o "$runtime" $objects -lm -ldl
```

- [ ] **Step 3: Verify exact ABI and loader name**

Run: `LD_LIBRARY_PATH="$prefix/lib" "$prefix/bin/lua" -e 'assert(_VERSION == EXPECTED)'`

Run: `readelf -d "$prefix/lib/liblua.so.$abi" | grep "SONAME.*liblua.so.$abi"`

Expected: both commands PASS for every pinned version.

- [ ] **Step 4: Run the five-version native matrix**

Run: `HOST_LABEL=local-shared SOURCE_CACHE=/tmp/luai-shared-cache WORK_ROOT=/tmp/luai-shared-work EVIDENCE_DIR=/tmp/luai-shared-evidence sh tools/test-lua-versions.sh`

Expected: five PASS lines; each `toolchain_native` log reports `LINK_MODE=shared`.

- [ ] **Step 5: Commit shared-runtime matrix support**

```bash
git add tools/test-lua-versions.sh tools/remote-test-linux.sh test/version_contract.lua
git commit -m "test: build shared Lua runtimes on Linux"
```

### Task 3: Prefix layout and consistent loader environment

**Files:**
- Modify: `src/toolchain.lua:97-108,244-289,588-607,609-680`
- Modify: `test/production_edges.lua:2390-2500`

**Interfaces:**
- Produces: `findLinkedRuntime(config, executable, environment)`.
- Produces: prefix discovery over `lib`, `lib64`, and safe resolved symlinks.
- Consumes: explicit subprocess environment from `verifyCandidate`.

- [ ] **Step 1: Add RED prefix-layout tests**

Create private prefixes for `lib64`, `liblua.so -> liblua.so.<abi>`, and a
shared runtime requiring its prefix through `LD_LIBRARY_PATH`. Assert that
`toolchain.resolve({lua_prefix=prefix})` succeeds and returns the canonical
runtime file inside that prefix.

- [ ] **Step 2: Run the prefix tests and observe RED**

Run: `LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua`

Expected: the `lib64`/symlink case is not discovered, or `ldd` reports the
runtime as `not found` despite the compile/run probe succeeding.

- [ ] **Step 3: Implement safe prefix enumeration**

```lua
local function libraryDirectories(prefix)
    return {
        normalizePath(prefix .. "/lib"),
        normalizePath(prefix .. "/lib64"),
        normalizePath(prefix),
    }
end
```

Use `fs.isRegularFile` on the resolved target while preserving the requested
path for loader identity. Reject symlinks escaping the explicit prefix. Include
versioned names matching `liblua.so.<abi>`.

- [ ] **Step 4: Pass one environment to loader inspection**

```lua
local function findLinkedRuntime(config, executable, environment)
    local command = config.host.os == "macos" and "otool" or "ldd"
    local arguments = config.host.os == "macos" and { "-L", executable }
        or { executable }
    local ok, output = process.outputCommand(command, arguments, environment)
    if not ok then return nil, output end
    for line in tostring(output):gmatch("[^\r\n]+") do
        local candidate
        if config.host.os == "macos" then
            candidate = line:match("^%s*(/[^%s]*[Ll]ua[^%s]*%.dylib)")
        else
            candidate = line:match("=>%s+([^%s]+)")
                or line:match("^%s*(/[^%s]+)")
            if candidate and candidate ~= "not"
                and not path.basename(candidate):lower():find("lua", 1, true) then
                candidate = nil
            end
        end
        if candidate and regularFile(candidate) then
            return normalizePath(candidate)
        end
    end
    return nil, output
end
```

Call it with the exact environment used for the successful runtime probe.

- [ ] **Step 5: Run full edge and native tests**

Run: `LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua && lua test/toolchain_native.lua`

Expected: all prefix layouts PASS and no `liblua => not found` output remains.

- [ ] **Step 6: Commit prefix relocation fixes**

```bash
git add src/toolchain.lua test/production_edges.lua
git commit -m "fix: verify custom Lua prefixes consistently"
```

### Task 4: Staged real C-module verification

**Files:**
- Modify: `src/toolchain.lua:609-680`
- Modify: `test/native_bundle.lua:1-120`
- Modify: `test/native_onefile.lua:1-140`
- Create: `test/fixtures/native_probe.c`

**Interfaces:**
- Produces: fixture module `luaopen_luai_native_probe` returning
  `"native-probe-ok"`.
- Produces: internal `verifyNativeModuleCapability(config, work_dir)`.
- Consumed by: onedir and onefile clean-target tests.

- [ ] **Step 1: Add the ordinary C module fixture**

```c
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

int luaopen_luai_native_probe(lua_State *L) {
    lua_pushliteral(L, "native-probe-ok");
    return 1;
}
```

Compile it as a shared module without linking liblua. Add an entry script that
asserts `require("luai_native_probe") == "native-probe-ok"`.

- [ ] **Step 2: Run against the pre-fix static matrix and observe RED**

Run: `lua test/native_bundle.lua && lua test/native_onefile.lua`

Expected before Tasks 1-3: clean target fails with an undefined `lua_*` symbol
on static Linux.

- [ ] **Step 3: Verify native-module loading during toolchain probing**

Inside the private `verifyCandidate` directory, compile `native_probe.c` as a
loadable module without linking liblua. Generate a probe host using the same
compiler, Lua link arguments, and runtime environment as the real launcher:

```c
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
int main(void) {
    lua_State *L = luaL_newstate();
    int status;
    if (!L) return 2;
    luaL_openlibs(L);
    status = luaL_dostring(L,
        "package.cpath='./?." LUAI_NATIVE_EXTENSION "';"
        "assert(require('luai_native_probe') == 'native-probe-ok')");
    if (status != 0) {
        const char *message = lua_tostring(L, -1);
        if (message) fputs(message, stderr);
    }
    lua_close(L);
    return status == 0 ? 0 : 3;
}
```

On Linux, compile the module with `-shared -fPIC` and no liblua link. On macOS,
use `-bundle -undefined dynamic_lookup`. On Windows, compile a DLL against the
verified Lua import library. Define `LUAI_NATIVE_EXTENSION` as `so`, `dylib`,
or `dll` for the generated host. Run this host with its working directory set
to the private probe directory and the exact loader environment used by
`verifyCandidate`. A failure rejects the toolchain. The product artifact
receives no test-only CLI or environment path.

- [ ] **Step 4: Run onedir/onefile clean-target tests**

Run: `lua test/native_bundle.lua && lua test/native_onefile.lua`

Expected: both print their existing PASS markers plus `native-probe-ok`.

- [ ] **Step 5: Commit real native-module coverage**

```bash
git add src/toolchain.lua test/native_bundle.lua test/native_onefile.lua \
  test/fixtures/native_probe.c
git commit -m "test: verify staged Lua C modules"
```

### Task 5: Windows x64 CRT closure

**Files:**
- Modify: `src/toolchain.lua:123-181,492-578`
- Modify: `tools/test-lua-versions.ps1:95-176,215-230`
- Modify: `test/windows_native.lua:1-180`
- Modify: `docs/PLATFORMS-NATIVE-LIMITS.adoc:37-68,86-111`

**Interfaces:**
- Produces: MSVC compile arguments containing `/MT` and `/Brepro`.
- Produces: PE dependency audit with no `VCRUNTIME*.dll` or `ucrtbase.dll`.

- [ ] **Step 1: Add source/argument assertions**

```lua
assert(generated_command:find("/MT", 1, true))
assert(generated_command:find("/Brepro", 1, true))
assert(not generated_command:find("Hostx64/ARM64", 1, true))
```

PowerShell adds a dependency check:

```powershell
$deps = & $Dumpbin /dependents $Artifact | Out-String
if ($deps -match '(?im)^\s*(VCRUNTIME\d+|ucrtbase)\.dll\s*$') {
    throw "unexpected dynamic CRT dependency: $deps"
}
```

- [ ] **Step 2: Run Windows source-contract tests and observe RED**

Run on a native Windows x64 host:
`powershell -NoProfile -File tools/test-lua-versions.ps1 -HostLabel windows-red`

Expected: compile command or PE dependency assertion fails because `/MT` is
not currently explicit and matrix Lua uses `/MD`.

- [ ] **Step 3: Apply `/MT` consistently**

Add `/MT` to `M.compile`, `M.compileStandalone`, the Lua DLL matrix compile,
and any native validation fixture compiled by MSVC. Keep `/Brepro` on release
artifacts and use `/machine:X64` only after the platform guard has confirmed
x86_64.

- [ ] **Step 4: Run the complete Windows matrix in a clean VM**

Run: `powershell -NoProfile -File tools/test-lua-versions.ps1 -HostLabel windows11-clean`

Expected: five PASS lines, PE dependency audits pass, and onedir/onefile run in
a snapshot without Lua, LuaRocks, Visual Studio, or VC Redistributable.

- [ ] **Step 5: Commit Windows closure**

```bash
git add src/toolchain.lua tools/test-lua-versions.ps1 test/windows_native.lua \
  docs/PLATFORMS-NATIVE-LIMITS.adoc
git commit -m "fix: close Windows runtime dependencies"
```
