# Lua 5.x Native Platform Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the LuaRocks-installed `luai` and `luainstaller` commands build self-contained native bundles with Lua 5.1 through 5.5 on native Linux, macOS, Windows, and capability-compatible POSIX hosts.

**Architecture:** Keep one Lua 5.1-syntax codebase and centralize standard-library, bit-operation, process, and C-API differences behind focused compatibility/toolchain modules. Replace OS/profile whitelists with native-host capability resolution, retain the v2 security model, and drive all subprocesses with the exact interpreter and platform-specific quoting selected by the caller.

**Tech Stack:** Lua 5.1.5/5.2.4/5.3.6/5.4.8/5.5.0, LuaRocks builtin packaging, C11 launchers/extractors, GCC/Clang/MSVC-compatible native toolchains, POSIX shell release runners, PowerShell Windows runner.

## Global Constraints

- Runtime package range is `lua >= 5.1, < 6.0`; Lua 5.0 and LuaJIT remain rejected.
- Bundles are native same-environment artifacts bound to OS family, CPU architecture, system ABI, and Lua major/minor ABI.
- Cross-compilation is removed; an explicit non-host target fails before output mutation.
- A finished onedir or onefile runs without `lua`, `luac`, LuaRocks, system Lua libraries, or Lua environment variables.
- LuaRocks is the sole documented installation method and both command names work outside the checkout.
- Product source uses Lua 5.1 syntax; SHA-256, manifest v2, recursive ownership, safe replacement, cache, symlink, reparse, and logging defenses are preserved.
- Tested devices are evidence, never a platform whitelist.
- No release tag or LuaRocks publication is part of this plan.
- Push only the fully verified intended commits; never force-push.

---

### Task 1: Establish the multi-version executable contract

**Files:**
- Create: `test/version_contract.lua`
- Modify: `.gitattributes`
- Modify: `luainstaller-1.0.0-1.rockspec`
- Modify: `test/support/harness.lua`

**Interfaces:**
- Produces: `harness.luaCommand()` returning the exact configured interpreter command, and `harness.runLua(arguments, opts)` for child tests.
- Produces: the version contract `Lua >= 5.1, < 6.0`, with LuaJIT rejected by identity rather than version-number coincidence.

- [ ] **Step 1: Write the failing version/transport test**

```lua
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local compat = require("luainstaller.compat")
local info = compat.luaVersion()
assert(info.major == 5 and info.minor >= 1)
assert(info.abi == string.format("lua%d.%d", info.major, info.minor))
assert(harness.luaCommand() ~= "")
local output = harness.runLua({ "-e", "io.write(_VERSION)" })
assert(output == _VERSION)
print("version contract ok: " .. info.version)
```

Add `.gitattributes` rules:

```gitattributes
*.lua text eol=lf
*.sh text eol=lf
*.c text eol=lf
*.h text eol=lf
*.adoc text eol=lf
*.rockspec text eol=lf
*.txt text eol=lf
```

- [ ] **Step 2: Run the test under the current 5.4 and the Debian 5.1 interpreter to prove both failure modes**

Run:

```sh
lua test/version_contract.lua
ssh -p 26022 yynicepc@192.168.10.57 'cd /tmp/luainstaller-debian-current && lua5.1 test/version_contract.lua'
```

Expected: current Lua fails because `compat.luaVersion` and harness interpreter APIs do not exist; Lua 5.1 may fail earlier while parsing current product modules.

- [ ] **Step 3: Add exact interpreter propagation and broaden metadata**

Implement in `test/support/harness.lua`:

```lua
local configured_lua = os.getenv("LUAI_TEST_LUA") or (arg and arg[-1]) or "lua"

function M.luaCommand()
    return configured_lua
end

function M.runLua(arguments, opts)
    local command = M.command(configured_lua, arguments)
    return M.run(command, opts)
end
```

Change the rockspec dependency to:

```lua
dependencies = {
    "lua >= 5.1, < 6.0",
}
```

- [ ] **Step 4: Verify canonical LF and interpreter propagation**

Run:

```sh
git check-attr eol -- src/analyzer.lua test/smoke_all.lua README.adoc
LUAI_TEST_LUA="$(command -v lua)" lua test/version_contract.lua
git diff --check
```

Expected: all three queried text files report `eol: lf`; version contract prints success.

- [ ] **Step 5: Commit**

```sh
git add .gitattributes luainstaller-1.0.0-1.rockspec test/support/harness.lua test/version_contract.lua
git commit -m "test: establish Lua 5.x version contract"
```

### Task 2: Build the Lua 5.1 compatibility primitives

**Files:**
- Modify: `src/compat.lua`
- Modify: `src/hash.lua`
- Modify: `src/fs.lua`
- Test: `test/version_contract.lua`
- Test: `test/production_edges.lua`

**Interfaces:**
- Produces: `compat.luaVersion()`, `compat.isSupportedLua()`, `compat.loadText(source, name, env)`, `compat.unpack(values, first, last)`, and `compat.searchpath(name, path)`.
- Produces: `compat.band/bor/bxor/bnot/lshift/rshift/rrotate` and `compat.packU32BE` operating on unsigned 32-bit values without post-5.1 syntax.

- [ ] **Step 1: Extend the failing test with known compatibility vectors**

```lua
assert(compat.band(0xf0, 0x3c) == 0x30)
assert(compat.bor(0xf0, 0x0f) == 0xff)
assert(compat.bxor(0xaa, 0xff) == 0x55)
assert(compat.rrotate(0x12345678, 8) == 0x78123456)
assert(compat.packU32BE(0x12345678) == "\18\52\86\120")
local chunk = assert(compat.loadText("return value", "@compat", { value = 42 }))
assert(chunk() == 42)
local bytecode = string.dump(function() return true end)
assert(compat.loadText(bytecode, "@bytecode", {}) == nil)
```

- [ ] **Step 2: Confirm the vectors fail before implementation**

Run: `lua test/version_contract.lua`

Expected: FAIL at the first missing bit/load helper.

- [ ] **Step 3: Implement arithmetic 32-bit and standard-library adapters in Lua 5.1 syntax**

Use modulo arithmetic with `UINT32 = 4294967296`, per-bit loops for boolean operations, and `math.floor(value / 2 ^ count)` for shifts. Implement text-only 5.1 loading as:

```lua
function M.loadText(source, chunk_name, environment)
    if type(source) ~= "string" or source:byte(1) == 27 then
        return nil, "binary chunks are not accepted"
    end
    if _VERSION == "Lua 5.1" then
        local loader, err = loadstring(source, chunk_name)
        if loader and environment then setfenv(loader, environment) end
        return loader, err
    end
    return load(source, chunk_name, "t", environment)
end
```

- [ ] **Step 4: Replace native bit operators and `string.pack` in hashing/base64 paths**

`src/hash.lua` imports `luainstaller.compat` and uses the helpers for every SHA-256 and FNV operation. `src/fs.lua` uses arithmetic base64 packing rather than `<<`, `>>`, `|`, and `&`.

- [ ] **Step 5: Verify hashes on Lua 5.1 and current Lua**

Run:

```sh
lua test/version_contract.lua
lua -e 'local h=dofile("test/support/harness.lua");h.install_loader();assert(require("luainstaller.hash").sha256("abc")=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")'
```

Expected: PASS with the SHA-256 known vector and bytecode rejection.

- [ ] **Step 6: Commit**

```sh
git add src/compat.lua src/hash.lua src/fs.lua test/version_contract.lua test/production_edges.lua
git commit -m "feat: add Lua 5.1 compatibility primitives"
```

### Task 3: Make analysis, discovery, logging, and generated Lua parse on every Lua 5.x

**Files:**
- Modify: `src/analyzer.lua`
- Modify: `src/discovery.lua`
- Modify: `src/logger.lua`
- Modify: `src/runtime.lua`
- Modify: `src/cgen.lua`
- Modify: `src/manifest.lua`
- Modify: `src/init.lua`
- Test: `test/version_contract.lua`
- Test: `test/contract_docs.lua`
- Test: `test/production_edges.lua`

**Interfaces:**
- Consumes: compatibility primitives from Task 2.
- Produces: all public Lua modules parse and load under each configured Lua 5.x interpreter.
- Produces: runtime discovery subprocesses always use `opts.lua` or the current exact interpreter, never a bare `lua` fallback when a verified interpreter is available.

- [ ] **Step 1: Add a source parser/load sweep and runtime-interpreter regression**

```lua
for path in harness.listTrackedLua("src") do
    local chunk, err = loadfile(path)
    assert(chunk, path .. ": " .. tostring(err))
end
local traced = require("luainstaller").trace({
    entry = "test/runtime_bundle/main.lua",
    discovery_mode = "runtime",
    lua = harness.luaCommand(),
})
assert(traced.ok, traced.error and traced.error.message)
```

- [ ] **Step 2: Run under Lua 5.1 to capture every syntax/API failure**

Run: `LUAI_TEST_LUA=/usr/bin/lua5.1 /usr/bin/lua5.1 test/version_contract.lua`

Expected: FAIL on current `goto`/label or `load(..., "t", env)` usage.

- [ ] **Step 3: Convert product control flow to Lua 5.1 syntax**

Replace analyzer labels with local helper functions/structured loops. Replace direct `load` calls in analyzer/logger/runtime/generated bootstrap with `compat.loadText`; replace `table.unpack` with `compat.unpack`; replace `package.searchpath` with `compat.searchpath`.

- [ ] **Step 4: Propagate selected interpreter through discovery**

Normalize the interpreter once:

```lua
local interpreter = opts.lua or os.getenv("LUAI_LUA") or compat.currentInterpreter()
local ok, observed = discovery.probeInterpreter(interpreter)
if not ok or observed.abi ~= compat.luaVersion().abi then
    return result.error("ToolchainError", "Runtime discovery Lua ABI mismatch", {
        expected = compat.luaVersion().abi,
        observed = observed and observed.abi,
    })
end
```

- [ ] **Step 5: Run CLI, documentation, discovery, and log contracts under the oldest and newest interpreters available**

Run:

```sh
LUAI_TEST_LUA=/usr/bin/lua5.1 /usr/bin/lua5.1 test/version_contract.lua
lua test/cli_split_smoke.lua
lua test/contract_docs.lua
```

Expected: PASS; no child command resolves Debian `/usr/bin/lua` when `LUAI_TEST_LUA` names another interpreter.

- [ ] **Step 6: Commit**

```sh
git add src/analyzer.lua src/discovery.lua src/logger.lua src/runtime.lua src/cgen.lua src/manifest.lua src/init.lua test/version_contract.lua test/contract_docs.lua test/production_edges.lua
git commit -m "feat: run analysis on Lua 5.1 through 5.5"
```

### Task 4: Generate ABI-specific launchers and manifests

**Files:**
- Modify: `src/launcher.lua`
- Modify: `src/launcher/luai_launcher.c`
- Modify: `src/cgen.lua`
- Modify: `src/manifest.lua`
- Modify: `src/bundler.lua`
- Test: `test/production_edges.lua`
- Test: `test/smoke_all.lua`

**Interfaces:**
- Consumes: `compat.luaVersion()` from Task 2.
- Produces: `launcher.generate({ lua_version = info, ... })` with an exact `LUA_VERSION_NUM` guard.
- Produces: manifest `lua.version`, `lua.major`, `lua.minor`, `lua.abi`, and payload identity that varies with Lua ABI.

- [ ] **Step 1: Write failing generated-source assertions for 5.1 and 5.5**

```lua
local source51 = launcher.generate({ lua_version = { major = 5, minor = 1, num = 501 } })
assert(source51:find("LUA_VERSION_NUM != 501", 1, true))
assert(source51:find("luaL_loadbuffer", 1, true))
local source55 = launcher.generate({ lua_version = { major = 5, minor = 5, num = 505 } })
assert(source55:find("LUA_VERSION_NUM != 505", 1, true))
assert(not source55:find("Lua 5.4", 1, true))
```

- [ ] **Step 2: Verify current templates fail the dynamic assertions**

Run: `EDGE_FILTER='target launcher' lua test/production_edges.lua`

Expected: FAIL because the template contains `504` and `Lua 5.4`.

- [ ] **Step 3: Parameterize C source and protect Lua 5.1 text loading**

Emit:

```c
#if LUA_VERSION_NUM != @LUA_VERSION_NUM@
#error "luainstaller was generated for a different Lua ABI"
#endif
#if LUA_VERSION_NUM == 501
#define LUAI_LOAD_TEXT(L,b,n,name) (((unsigned char)(b)[0] == 0x1b) ? LUA_ERRSYNTAX : luaL_loadbuffer((L),(b),(n),(name)))
#else
#define LUAI_LOAD_TEXT(L,b,n,name) luaL_loadbufferx((L),(b),(n),(name),"t")
#endif
```

Use version-neutral `lua_pcall`, which is available across the required C APIs.

- [ ] **Step 4: Make the linked probe compare the selected `_VERSION`**

Generate the expected string (`Lua 5.1` through `Lua 5.5`) and include expected/observed values in structured `ToolchainError` data.

- [ ] **Step 5: Verify manifest/cache separation and strict C compilation**

Run:

```sh
EDGE_FILTER='target launcher|linked Lua runtime|onefile repeated' lua test/production_edges.lua
lua test/contract_docs.lua
```

Expected: PASS; two manifests built with different mocked ABIs have different payload/cache identities.

- [ ] **Step 6: Commit**

```sh
git add src/launcher.lua src/launcher/luai_launcher.c src/cgen.lua src/manifest.lua src/bundler.lua test/production_edges.lua test/smoke_all.lua
git commit -m "feat: generate Lua ABI-specific launchers"
```

### Task 5: Replace platform whitelists with native capability and toolchain resolution

**Files:**
- Create: `src/toolchain.lua`
- Modify: `src/platform.lua`
- Modify: `src/init.lua`
- Modify: `src/compat.lua`
- Modify: `luainstaller-1.0.0-1.rockspec`
- Test: `test/contract_docs.lua`
- Test: `test/production_edges.lua`

**Interfaces:**
- Produces: `toolchain.resolve(opts) -> config|nil, structured_error`.
- `config` contains `host`, `lua_version`, `cc`, `compiler_family`, `include_dir`, `library_dir`, `runtime_path`, `link_args`, `executable_suffix`, and `native_extensions`.
- Produces: `platform.profile(opts)` for the detected native host; an explicit mismatched target returns `UnsupportedPlatformError` before filesystem mutation.

- [ ] **Step 1: Add failing native-only/capability tests**

```lua
local host = platform.detectHost()
local native = assert(platform.profile({ target_os = host.os }))
assert(native.target_os == host.os)
local mismatch = require("luainstaller").bundle({
    entry = fixture,
    out = output,
    target_os = host.os == "windows" and "linux" or "windows",
})
assert(mismatch.error.type == "UnsupportedPlatformError")
assert(not harness.exists(output))
```

- [ ] **Step 2: Confirm the old whitelist/cross-profile behavior fails the contract**

Run: `lua test/contract_docs.lua`

Expected: FAIL where the API accepts a cross target or restricts unknown POSIX host names.

- [ ] **Step 3: Implement ordered toolchain discovery**

Resolve explicit options/environment first, active Lua executable/prefix second, `luarocks config variables.*` third, and `pkg-config` fourth on POSIX. Validate candidates by compiling and executing a probe; never trust filenames alone.

- [ ] **Step 4: Remove Windows cross defaults and OS validation list**

Delete fixed `x86_64-w64-mingw32-gcc`, Wine, and `VALID_TARGET_OS`. Preserve `target_os` only as a native-host assertion. Add `luainstaller.toolchain = "src/toolchain.lua"` to the rockspec and checkout preloads.

- [ ] **Step 5: Verify toolchain diagnostics on Linux, macOS, and Windows fixtures**

Run:

```sh
lua test/contract_docs.lua
EDGE_FILTER='platform|toolchain|pkg-config|linked Lua runtime' lua test/production_edges.lua
```

Expected: PASS with structured missing-compiler, missing-header, ABI-mismatch, and cross-target errors.

- [ ] **Step 6: Commit**

```sh
git add src/toolchain.lua src/platform.lua src/init.lua src/compat.lua src/cli.lua luainstaller-1.0.0-1.rockspec test/contract_docs.lua test/production_edges.lua
git commit -m "feat: resolve native host toolchains by capability"
```

### Task 6: Make process and filesystem operations native on Windows

**Files:**
- Modify: `src/process.lua`
- Modify: `src/fs.lua`
- Modify: `src/path.lua`
- Modify: `src/logger.lua`
- Test: `test/windows_native.lua`
- Test: `test/production_edges.lua`

**Interfaces:**
- Produces: `process.quote(value)`, `process.command(executable, args, env)`, and `process.outputCommand(executable, args, env)` with POSIX and Windows implementations.
- Produces: `fs.pathType`, `fs.makePrivateDirectory`, `fs.listTree`, `fs.copyFile`, `fs.removeFile`, and guarded tree cleanup without Bash on Windows.

- [ ] **Step 1: Create failing Windows-native quoting/filesystem tests**

```lua
local process = require("luainstaller.process")
local fs = require("luainstaller.fs")
local argument = [[say "hello"\trail\]]
local ok, output = process.outputCommand(harness.luaCommand(), {
    "-e", "io.write(arg[1])", argument,
})
assert(ok and output == argument)
assert(fs.pathType(harness.regularFile()) == "file")
assert(fs.pathType(harness.directory()) == "directory")
assert(fs.pathType(harness.reparsePoint()) == "reparse")
```

- [ ] **Step 2: Run natively on Windows and capture POSIX quote/tool failures**

Run:

```powershell
$env:LUAI_TEST_LUA = '<absolute Lua 5.4 path>'
& $env:LUAI_TEST_LUA test/windows_native.lua
```

Expected: FAIL because current process quoting is POSIX-only and filesystem traversal shells out to POSIX tools.

- [ ] **Step 3: Implement Windows command quoting and PowerShell-backed filesystem primitives**

Use the documented `CommandLineToArgvW` inverse quoting rule for process arguments. Invoke the absolute System PowerShell path with `-EncodedCommand`; encode paths/operation records as Base64 so shell metacharacters are never interpolated. Reject reparse points and device paths before mutation.

- [ ] **Step 4: Route logger and path checks through `fs`/`process`**

Remove direct Windows uses of `test`, `mkdir`, `chmod`, `stat`, `rm`, and POSIX single-quote construction. Retain POSIX implementations behind the same interfaces.

- [ ] **Step 5: Verify metacharacters, non-ASCII paths, reparse points, and clean PATH**

Run: `& $env:LUAI_TEST_LUA test/windows_native.lua`

Expected: PASS with `PATH=C:\Windows\System32;C:\Windows`, a HOME containing `&A%caret^bang!`, and a representable non-ASCII file.

- [ ] **Step 6: Commit**

```sh
git add src/process.lua src/fs.lua src/path.lua src/logger.lua test/windows_native.lua test/production_edges.lua
git commit -m "feat: add native Windows process and filesystem backend"
```

### Task 7: Build onedir natively on POSIX, macOS, and Windows

**Files:**
- Modify: `src/bundler.lua`
- Modify: `src/toolchain.lua`
- Modify: `src/launcher.lua`
- Modify: `src/launcher/luai_launcher.c`
- Test: `test/native_bundle.lua`
- Test: `test/smoke_all.lua`

**Interfaces:**
- Consumes: toolchain config from Task 5 and process/fs primitives from Task 6.
- Produces: `bundler.bundleOnedir(opts)` using only the native host toolchain and copying/linking the exact selected Lua runtime.

- [ ] **Step 1: Add a failing native onedir clean-target test**

```lua
local result = require("luainstaller").bundle({
    entry = "test/runtime_bundle/main.lua",
    out = harness.tempPath("native-runtime"),
    mode = "onedir",
})
assert(result.ok, result.error and result.error.message)
local output = harness.runClean(result.executable, { "native-clean" })
assert(output:find("hello native-clean", 1, true))
harness.assertBundledLuaRuntime(result)
```

- [ ] **Step 2: Confirm Windows rejects the build and POSIX still assumes 5.4**

Run on each native host: `<selected-lua> test/native_bundle.lua`

Expected: Windows FAILS with the current Linux+MinGW error; non-5.4 POSIX fails its hard-coded ABI check.

- [ ] **Step 3: Compile through the resolved compiler family**

Build an argument vector from `toolchain.resolve`. GCC/Clang use `-I`, `-L`, `-o`, rpath/import-library flags; MSVC uses `/I`, `/Fe:`, `/link`, and the resolved Lua import library. Execute the linked ABI probe before publishing.

- [ ] **Step 4: Copy or statically link the exact Lua runtime**

On shared-runtime profiles, identify the probe's loaded Lua library and copy it under `.luai/native` (or beside the Windows executable as required). On static macOS profiles, verify the selected archive and record its hash. Reject any dependency on a system Lua location during the clean-target inspection.

- [ ] **Step 5: Run native onedir, output replacement, and failed-rebuild gates**

Run:

```sh
lua test/native_bundle.lua
lua test/contract_docs.lua
EDGE_FILTER='output|onedir|linked Lua runtime|Source changed' lua test/production_edges.lua
```

Expected: PASS on Linux/macOS/Windows; previous output remains runnable after an injected compiler failure.

- [ ] **Step 6: Commit**

```sh
git add src/bundler.lua src/toolchain.lua src/launcher.lua src/launcher/luai_launcher.c test/native_bundle.lua test/smoke_all.lua test/production_edges.lua
git commit -m "feat: build native onedir bundles on every host"
```

### Task 8: Build and execute onefile natively on every host

**Files:**
- Modify: `src/onefile.lua`
- Modify: `src/toolchain.lua`
- Test: `test/native_bundle.lua`
- Test: `test/production_edges.lua`
- Test: `test/smoke_all.lua`

**Interfaces:**
- Consumes: native onedir and toolchain/process/fs interfaces.
- Produces: native onefile compilation, secure extraction, ABI-separated payload identity, argument forwarding, and clean-target execution.

- [ ] **Step 1: Extend the failing native bundle test**

```lua
local first = harness.buildRuntime("onefile")
local second = harness.buildRuntime("onefile")
assert(harness.sha256File(first.executable) == harness.sha256File(second.executable))
assert(harness.runClean(first.executable, { [[C:\Alpha Beta\trail\]], "" })
    :find([[hello C:\Alpha Beta\trail\]], 1, true))
harness.assertPrivateOnefileCache(first)
```

- [ ] **Step 2: Run on Windows and a non-5.4 POSIX interpreter**

Expected: FAIL in current cross-compiler/hard-coded payload code.

- [ ] **Step 3: Compile extractor with native compiler settings and dynamic ABI payload metadata**

Remove Wine/cross compiler selection. Include `lua.abi` in payload identity. Preserve strict path validation, ACL/mode enforcement, no-follow behavior, hard-link/atomic publication, and live payload pinning.

- [ ] **Step 4: Verify concurrent cache and repair behavior**

Run 12 concurrent users, remove executable mode on POSIX, loosen a Windows ACL, and rerun. Expect all users to succeed and the cache to be repaired before reuse.

- [ ] **Step 5: Run strict C and sanitizer gates**

Run project-generated C with `-std=c11 -Wall -Wextra -Werror -pedantic`; execute ASan/UBSan builds where the native compiler supports them. MSVC uses `/W4 /WX`.

- [ ] **Step 6: Commit**

```sh
git add src/onefile.lua src/toolchain.lua test/native_bundle.lua test/production_edges.lua test/smoke_all.lua
git commit -m "feat: build secure native onefile bundles"
```

### Task 9: Make LuaRocks installation the complete distribution surface

**Files:**
- Modify: `luainstaller-1.0.0-1.rockspec`
- Modify: `src/cli.lua`
- Delete: `tools/install-source.sh`
- Modify: `test/smoke_all.lua`
- Modify: `test/contract_docs.lua`
- Test: `test/luarocks_install.lua`

**Interfaces:**
- Produces: installed `luai` and `luainstaller` commands that load all modules/toolchain data without checkout-relative paths.
- Removes: source-install release contract.

- [ ] **Step 1: Add an isolated LuaRocks install/build test**

```lua
local tree = harness.tempPath("rocktree-" .. require("luainstaller.compat").luaVersion().abi)
harness.run({ "luarocks", "make", "--tree", tree, "luainstaller-1.0.0-1.rockspec" })
local luai = harness.rockCommand(tree, "luai")
assert(harness.runCommand(luai, { "-v" }) == "luai 1.0.0\n")
harness.copyFixtureOutsideCheckout()
harness.assertInstalledBundle(luai)
```

- [ ] **Step 2: Confirm installed toolchain module/Windows build is missing**

Run: `lua test/luarocks_install.lua`

Expected: FAIL until every new module is in the rockspec and checkout-only source install assumptions are removed.

- [ ] **Step 3: Complete rockspec modules/bin metadata and CLI lookup**

Add `luainstaller.toolchain`, retain both binaries, resolve a bare installed command through platform-native PATH lookup, and emit `LGPL-3.0-or-later` in version output.

- [ ] **Step 4: Remove source installer tests and file**

Delete only assertions and documentation contracts for `tools/install-source.sh`; retain negative Lua ABI/toolchain tests through LuaRocks/native bundle tests.

- [ ] **Step 5: Run lint and isolated installation under every configured interpreter**

Run: `luarocks lint luainstaller-1.0.0-1.rockspec` and `lua test/luarocks_install.lua`.

Expected: PASS outside the checkout with no source preloads.

- [ ] **Step 6: Commit**

```sh
git add -A luainstaller-1.0.0-1.rockspec src/cli.lua tools/install-source.sh test/smoke_all.lua test/contract_docs.lua test/luarocks_install.lua
git commit -m "feat: make LuaRocks the complete installation path"
```

### Task 10: Add portable Lua-version and physical-device release runners

**Files:**
- Create: `tools/test-lua-versions.sh`
- Create: `tools/test-lua-versions.ps1`
- Modify: `tools/remote-test-linux.sh`
- Modify: `tools/remote-test-macos.sh`
- Replace: `tools/remote-test-windows.sh`
- Modify: `test/production_edges.lua`
- Modify: `test/README.adoc`

**Interfaces:**
- Produces: verified source cache pins for Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8, 5.5.0 and compatible LuaRocks.
- Produces: per-interpreter `LUAI_TEST_LUA`, LuaRocks tree, compiler configuration, logs, and explicit core/native result categories.

- [ ] **Step 1: Add failing script-contract assertions**

Assert that every runner contains all five version pins, uses canonical Git archive bytes, never invokes a bare test `lua`, rejects unsafe temporary roots, and has no Wine/Windows VM/cross compiler requirement.

- [ ] **Step 2: Run the script contract to demonstrate current omissions**

Run: `EDGE_FILTER='remote scripts' lua test/production_edges.lua`

Expected: FAIL on missing versions, worktree-byte tar, hard-coded `lua`, Wine, and VM targets.

- [ ] **Step 3: Implement POSIX version runner**

Download each official archive to an owner-only cache, verify pinned SHA-256, build an isolated prefix/shared runtime, build a matching LuaRocks tree, and execute the nine version gates from the design. Accept an explicit host label and output directory for preserved evidence.

- [ ] **Step 4: Implement Windows physical-machine runner**

PowerShell builds/uses each native Lua prefix, installs the rock, runs the portable/core/native bundle suites, checks DLL closure with native tools, clears Lua variables, narrows PATH, and verifies cache ACL/reparse behavior. It never requires SSH, Wine, or a VM.

- [ ] **Step 5: Update physical Linux/macOS orchestration**

Use `git archive --format=tar HEAD` rather than tarring checkout bytes. Run the five-version core/package matrix once per OS family and the full latest-version application/security suite on Debian, Rocky, DGX, Mac mini, and Mac Studio.

- [ ] **Step 6: Verify all runner safety contracts locally**

Run:

```sh
for script in tools/*.sh; do sh -n "$script"; done
lua test/production_edges.lua
```

Expected: PASS with no obsolete VM, Wine, source-installer, or cross-build assertions.

- [ ] **Step 7: Commit**

```sh
git add tools/test-lua-versions.sh tools/test-lua-versions.ps1 tools/remote-test-linux.sh tools/remote-test-macos.sh tools/remote-test-windows.sh test/production_edges.lua test/README.adoc
git commit -m "test: cover every Lua 5.x ABI on physical hosts"
```

### Task 11: Rewrite public documentation and release/legal metadata

**Files:**
- Create: `CHANGELOG.adoc`
- Create: `COPYING`
- Modify: `LICENSE`
- Modify: `README.adoc`
- Modify: `docs/USAGE.adoc`
- Modify: `docs/BUNDLING.adoc`
- Modify: `docs/PLATFORMS-NATIVE-LIMITS.adoc`
- Modify: `docs/TROUBLESHOOTING.adoc`
- Modify: `docs/IMPLEMENTATION.adoc`
- Modify: `docs/TESTING.adoc`
- Modify: `luainstaller.1`
- Modify: `luainstaller-1.0.0-1.rockspec`
- Modify: `test/contract_docs.lua`

**Interfaces:**
- Produces: one public contract separating capabilities from exact tested-device evidence.
- Produces: consistent `LGPL-3.0-or-later` notices and complete GPL/LGPL license texts.

- [ ] **Step 1: Replace documentation-contract expectations before prose**

Add assertions for `lua >= 5.1, < 6`, LuaRocks-only install, native-only builds, clean-target behavior, all six physical devices, and the absence of “supported target profiles”/Wine/VM/source-install claims.

- [ ] **Step 2: Run the contract to prove current documentation is stale**

Run: `lua test/contract_docs.lua`

Expected: FAIL on the first hard-coded Lua 5.4 or fixed profile statement.

- [ ] **Step 3: Rewrite user and maintainer documents**

Describe ABI binding, capability discovery, Lua-version selection, LuaRocks installation, native compiler requirements, clean-target verification, native-module closure, platform diagnostics, and the exact device/version matrix. Use devices only under “Tested devices”.

- [ ] **Step 4: Add release notes and license material**

`CHANGELOG.adoc` records the 1.0.0 feature/security contract and known technical limits. Keep the LGPL v3 supplemental text in `LICENSE`, add the GNU GPL v3 text as `COPYING`, and identify the project as `LGPL-3.0-or-later` in README, man page, rockspec, and CLI.

- [ ] **Step 5: Verify prose, commands, xrefs, metadata, and manual page**

Run:

```sh
lua test/contract_docs.lua
luarocks lint luainstaller-1.0.0-1.rockspec
rg -n 'Lua 5\.4 is the only|Wine|Windows 10 VM|install-source|verified target profiles' README.adoc docs luainstaller.1 luainstaller-1.0.0-1.rockspec
```

Expected: contract/lint PASS; the final search returns no obsolete public claim.

- [ ] **Step 6: Commit**

```sh
git add CHANGELOG.adoc COPYING LICENSE README.adoc docs luainstaller.1 luainstaller-1.0.0-1.rockspec src/cli.lua test/contract_docs.lua
git commit -m "docs: publish Lua 5.x native compatibility contract"
```

### Task 12: Complete local, version, device, review, and push gates

**Files:**
- Modify only when a failing gate has a root-cause regression test in the owning task.
- Evidence: command output retained outside the tracked repository or in the approved release log location.

**Interfaces:**
- Consumes: every prior task.
- Produces: one verified commit on `main`, pushed normally to `origin/main`; no tag or published rock.

- [ ] **Step 1: Run local repository and current-interpreter gates**

```sh
git diff --check
for script in tools/*.sh; do sh -n "$script"; done
lua test/version_contract.lua
lua test/cli_split_smoke.lua
lua test/contract_docs.lua
LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua
lua test/smoke_all.lua
luarocks lint luainstaller-1.0.0-1.rockspec
```

Expected: every command exits 0 with no unexplained skip.

- [ ] **Step 2: Run the five-version core/package/native matrix on one host per OS family**

```sh
sh tools/test-lua-versions.sh
powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-lua-versions.ps1
```

Run the shell matrix on Linux and macOS through the remote orchestrators. Expected: 5.1.5, 5.2.4, 5.3.6, 5.4.8, and 5.5.0 each report syntax, CLI, docs, edge, discovery, LuaRocks install, onedir, onefile, deterministic rebuild, and clean-target success.

- [ ] **Step 3: Run the latest complete physical-device matrix**

```sh
sh tools/remote-test-linux.sh
MAC_HOST=yymac06 sh tools/remote-test-macos.sh
MAC_HOST=yymacstudio sh tools/remote-test-macos.sh
powershell -NoProfile -ExecutionPolicy Bypass -File tools/remote-test-windows.sh
```

Expected: local Windows, Debian, Rocky, DGX Ubuntu, Mac mini, and Mac Studio all report their explicit final success marker.

- [ ] **Step 4: Review the final diff and repository state**

```sh
git status --short
git diff cc303c65e4eb94f7fa59fb6934b48738953040a9..HEAD --stat
git diff cc303c65e4eb94f7fa59fb6934b48738953040a9..HEAD --check
git log --oneline --decorate -15
```

Expected: no uncommitted changes, no unrelated file, no tag, and only intentional focused commits after the design/plan commits.

- [ ] **Step 5: Perform completion verification and normal push**

```sh
git fetch origin
git merge-base --is-ancestor origin/main HEAD
git push origin main
git fetch origin
test "$(git rev-parse origin/main)" = "$(git rev-parse HEAD)"
```

Expected: non-force push succeeds and the remote main hash equals the fully verified local hash.
