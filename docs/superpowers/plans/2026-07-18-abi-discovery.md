# ABI and Runtime Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make builtin-module classification and runtime discovery use one exact, official Lua major/minor ABI.

**Architecture:** Add `luainstaller.lua_abi` as the sole ABI capability table. Analyzer and discovery consume it; runtime discovery verifies explicit or inferred interpreters before tracing and records the verified ABI.

**Tech Stack:** Portable Lua 5.1-5.5, existing result/process/path helpers, LuaRocks builtin packaging.

## Global Constraints

- Support official Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8, and 5.5.0; reject LuaJIT.
- Analyzer, tracer, headers, linked runtime, and native modules must have one exact major/minor ABI.
- Preserve the current public CLI grammar and structured result/error format.
- Write a failing regression before each production change.
- Do not depend on a system `lua` command at packaged-program runtime.

---

### Task 1: Central ABI capability module

**Files:**
- Create: `src/lua_abi.lua`
- Create: `test/lua_abi.lua`
- Modify: `src/analyzer.lua:44-57,849-856`
- Modify: `src/cli.lua:55-115`
- Modify: `test/support/harness.lua:43-65`
- Modify: `luainstaller-1.0.0-1.rockspec:43-67`
- Modify: `test/version_contract.lua:85-110`

**Interfaces:**
- Produces: `lua_abi.normalize(value) -> "5.x"|nil`.
- Produces: `lua_abi.current() -> "5.x"|nil, reason`.
- Produces: `lua_abi.isOfficialCurrent() -> boolean`.
- Produces: `lua_abi.isBuiltin(abi, module_name) -> boolean`.
- Consumed by: analyzer and runtime discovery.

- [ ] **Step 1: Write the ABI table regression**

```lua
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local abi = require("luainstaller.lua_abi")

assert(abi.isBuiltin("5.1", "utf8") == false)
assert(abi.isBuiltin("5.2", "utf8") == false)
assert(abi.isBuiltin("5.3", "utf8") == true)
assert(abi.isBuiltin("5.4", "utf8") == true)
assert(abi.isBuiltin("5.5", "utf8") == true)
assert(abi.isBuiltin("5.1", "bit32") == false)
assert(abi.isBuiltin("5.2", "bit32") == true)
assert(abi.isBuiltin("5.3", "bit32") == true)
assert(abi.isBuiltin("5.4", "bit32") == false)
assert(abi.isBuiltin("5.5", "bit32") == false)
assert(abi.normalize(_VERSION) == tostring(_VERSION):match("Lua%s+(%d+%.%d+)"))
print("lua ABI capabilities ok")
```

- [ ] **Step 2: Run the new test and observe RED**

Run: `lua test/lua_abi.lua`

Expected: FAIL with `module 'luainstaller.lua_abi' not found`.

- [ ] **Step 3: Implement the focused module**

```lua
local M = {}

local COMMON = {
    _G = true, coroutine = true, debug = true, io = true, math = true,
    os = true, package = true, string = true, table = true,
}
local EXTRA = {
    ["5.1"] = {},
    ["5.2"] = { bit32 = true },
    ["5.3"] = { bit32 = true, utf8 = true },
    ["5.4"] = { utf8 = true },
    ["5.5"] = { utf8 = true },
}

function M.normalize(value)
    local major, minor = tostring(value or ""):match("Lua%s+(%d+)%.(%d+)")
    if not major then
        major, minor = tostring(value or ""):match("^(%d+)%.(%d+)$")
    end
    local abi = major and minor and (major .. "." .. minor) or nil
    return EXTRA[abi] and abi or nil
end

function M.current()
    local abi = M.normalize(_VERSION)
    local jit_value = rawget(_G, "jit")
    local is_luajit = type(jit_value) == "table"
        and type(jit_value.version) == "string"
        and type(jit_value.status) == "function"
    if not abi or is_luajit then
        return nil, "expected official Lua 5.1 through 5.5"
    end
    return abi
end

function M.isOfficialCurrent()
    return M.current() ~= nil
end

function M.isBuiltin(abi, name)
    local extras = EXTRA[M.normalize(abi)]
    return extras ~= nil and (COMMON[name] == true or extras[name] == true)
end

return M
```

Add the module to the checkout preload list, test harness, rockspec module map,
and production-source version contract. Replace analyzer's fixed table lookup
with `lua_abi.isBuiltin(assert(lua_abi.current()), module_name)`.

- [ ] **Step 4: Run focused and analyzer regressions**

Run: `lua test/lua_abi.lua && lua test/production_edges.lua`

Expected: `lua ABI capabilities ok` and `production edges passed: 94`.

- [ ] **Step 5: Commit the ABI capability unit**

```bash
git add src/lua_abi.lua src/analyzer.lua src/cli.lua test/support/harness.lua \
  test/lua_abi.lua test/version_contract.lua luainstaller-1.0.0-1.rockspec
git commit -m "fix: classify builtins by Lua ABI"
```

### Task 2: Exact interpreter validation and inference

**Files:**
- Modify: `src/discovery.lua:89-126,635-658`
- Modify: `src/manifest.lua:104-159,243-268`
- Modify: `test/production_edges.lua:1071-1083`
- Modify: `test/luarocks_install.lua:1-100`
- Modify: `docs/USAGE.adoc:113-135`
- Modify: `luainstaller.1:110-130`

**Interfaces:**
- Consumes: `lua_abi.current()` and `lua_abi.normalize(value)`.
- Produces: `validateLuaInterpreter(path, expected_abi) -> identity|nil, error`.
- Produces: `luaInterpreter(opts, expected_abi) -> identity|nil, error`, where
  identity is `{ path=string, abi=string, version=string }`.

- [ ] **Step 1: Add RED tests for cross-ABI and LuaRocks wrapper behavior**

Add a production-edge wrapper that reports a different official ABI during
the `-e` probe and assert:

```lua
local analyzed = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    discovery_mode = "runtime",
    lua = wrong_abi_wrapper,
    run_args = { "edge" },
})
assert(analyzed.ok == false)
assert(analyzed.error.type == "ToolchainError")
assert(analyzed.error.details.expected_abi == active_abi)
assert(analyzed.error.details.actual_abi == wrong_abi)
```

Extend the isolated LuaRocks install test to invoke the installed `luai` in
runtime mode without `--lua` and assert that it discovers
`test/runtime_bundle/greeter.lua`.

- [ ] **Step 2: Run both tests and observe RED**

Run: `lua test/production_edges.lua && lua test/luarocks_install.lua`

Expected: cross-ABI wrapper is incorrectly accepted and installed runtime
discovery returns `ToolchainError` before implementation.

- [ ] **Step 3: Implement exact candidate validation**

```lua
local function validateLuaInterpreter(interpreter, expected_abi)
    local ok, output = process.outputCommand(interpreter, { "-e", PROBE })
    local actual_abi = lua_abi.normalize(output)
    if not ok or not actual_abi or actual_abi ~= expected_abi then
        return nil, makeError("ToolchainError",
            "Runtime discovery interpreter must match the active Lua ABI", {
                interpreter = interpreter,
                expected_abi = expected_abi,
                actual_abi = actual_abi,
                output = output,
            })
    end
    return { path = interpreter, abi = actual_abi, version = output }
end
```

Candidate order is `opts.lua`, `LUAI_LUA`, then every nonempty string in the
negative argument vector from `arg[-1]` through `arg[-16]`. Each
inferred candidate is validated; failed inferred candidates are skipped, while
an explicit candidate returns its validation error. Fall back to `lua` only if
that executable also validates. Never accept a bootstrap source string.

- [ ] **Step 4: Reuse the verified identity for tracing**

Change `runtimePlan` to call `luaInterpreter(opts, assert(lua_abi.current()))`,
use `identity.path` for both command rendering and execution, and add
`interpreter={path=identity.path, abi=identity.abi}` to the discovery metadata
consumed by manifest construction.

- [ ] **Step 5: Run focused, install, and CLI contract tests**

Run: `lua test/production_edges.lua && lua test/luarocks_install.lua && lua test/contract_docs.lua`

Expected: all PASS and runtime discovery succeeds through the installed
LuaRocks wrapper without an explicit `--lua`.

- [ ] **Step 6: Commit interpreter identity enforcement**

```bash
git add src/discovery.lua src/manifest.lua test/production_edges.lua \
  test/luarocks_install.lua docs/USAGE.adoc luainstaller.1
git commit -m "fix: enforce runtime discovery ABI identity"
```

### Task 3: Five-version ABI verification

**Files:**
- Modify: `tools/test-lua-versions.sh:147-177`
- Modify: `tools/test-lua-versions.ps1:215-230`
- Modify: `docs/TESTING.adoc:63-105`

**Interfaces:**
- Consumes: `test/lua_abi.lua` and installed runtime-discovery test.
- Produces: saved per-version evidence proving builtin and discovery behavior.

- [ ] **Step 1: Add the ABI test to both matrix runners**

POSIX runner command:

```sh
"$lua" test/lua_abi.lua
```

PowerShell runner entry:

```powershell
foreach ($test in @('lua_abi.lua', 'version_contract.lua', 'cli_split_smoke.lua')) {
    Invoke-Native $lua @((Join-Path $SourceRoot "test\$test"))
}
```

- [ ] **Step 2: Run the local five-version matrix**

Run: `HOST_LABEL=local-abi SOURCE_CACHE=/tmp/luai-abi-cache WORK_ROOT=/tmp/luai-abi-work EVIDENCE_DIR=/tmp/luai-abi-evidence sh tools/test-lua-versions.sh`

Expected: five `PASS host=local-abi lua=<patch> abi=Lua 5.x` lines and every
evidence log contains `lua ABI capabilities ok`.

- [ ] **Step 3: Commit matrix coverage**

```bash
git add tools/test-lua-versions.sh tools/test-lua-versions.ps1 docs/TESTING.adoc
git commit -m "test: verify ABI behavior across official Lua versions"
```
