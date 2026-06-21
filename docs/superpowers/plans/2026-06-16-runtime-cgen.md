# Pure Lua Runtime Searcher And Cgen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a reusable pure Lua runtime searcher and bootstrap generator that can run embedded pure Lua payloads for single-file and multi-file samples.

**Architecture:** `src/runtime.lua` owns runtime behavior: source cleanup, bundled searcher installation, entry execution, and `arg` preservation. `src/cgen.lua` owns build-time payload creation and generated bootstrap source, embedding a minimal runtime copy for future C launcher reuse.

**Tech Stack:** Lua 5.4-compatible code, smoke tests in `test/smoke_all.lua`, small pure Lua fixture under `test/runtime_bundle/`, LuaRocks rockspec module install.

---

## File Structure

- Create `test/runtime_bundle/`: pure Lua multi-file fixture used by runtime and generated bootstrap tests.
- Modify `test/smoke_all.lua`: add runtime/cgen contract checks.
- Fill `src/runtime.lua`: strip source, install bundled searcher, run entry.
- Create `src/cgen.lua`: module name derivation, payload building, bootstrap source generation.
- Modify `luainstaller-1.0.0-1.rockspec`: install `luainstaller.runtime` and `luainstaller.cgen`.
- Modify `README.md`, `README-zh.md`: document pure Lua runtime bootstrap capability.

## Task 1: Runtime/Cgen Contract Tests

**Files:**
- Create: `test/runtime_bundle/main.lua`
- Create: `test/runtime_bundle/greeter.lua`
- Modify: `test/smoke_all.lua`

- [ ] **Step 1: Add fixture files**

Create `test/runtime_bundle/greeter.lua`:

```lua
--[[
Runtime bundle greeter fixture.

Author:
    WaterRun
File:
    greeter.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

function M.message(name)
    return "hello " .. tostring(name or "runtime")
end

return M
```

Create `test/runtime_bundle/main.lua`:

```lua
--[[
Runtime bundle entry fixture.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local greeter = require("greeter")
print(greeter.message(arg[1] or "runtime"))
print("entry=" .. tostring(arg[0]))
```

- [ ] **Step 2: Add smoke test loader mapping**

In `SOURCE_LOADER` in `test/smoke_all.lua`, add:

```lua
package.preload["luainstaller.runtime"] = function() return dofile("src/runtime.lua") end
package.preload["luainstaller.cgen"] = function() return dofile("src/cgen.lua") end
```

- [ ] **Step 3: Add runtime/cgen smoke function**

Add this function before the bottom calls:

```lua
local function check_runtime_cgen()
    local script = SOURCE_LOADER .. [[
local runtime = require("luainstaller.runtime")
local cgen = require("luainstaller.cgen")

local stripped = runtime.stripSource("\239\187\191#!/usr/bin/env lua\nprint('ok')")
assert(stripped == "print('ok')")

local previous_arg = _G.arg
_G.arg = { "outer" }
local payload = {
    entry = {
        id = "__entry__",
        path = "test/runtime_bundle/main.lua",
        source = "local greeter = require('greeter'); print(greeter.message(arg[1])); print('entry=' .. arg[0])",
    },
    modules = {
        greeter = {
            path = "test/runtime_bundle/greeter.lua",
            source = "return { message = function(name) return 'hello ' .. name end }",
        },
    },
}

local output = {}
local old_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    output[#output + 1] = table.concat(parts, "\t")
end

runtime.run(payload, { "direct" })
print = old_print
assert(_G.arg == previous_arg)
assert(output[1] == "hello direct")
assert(output[2] == "entry=test/runtime_bundle/main.lua")
_G.arg = previous_arg

local deps = {
    scripts = { "test/runtime_bundle/greeter.lua" },
    libraries = {},
}
local bootstrap = cgen.generateBootstrap({
    entry = "test/runtime_bundle/main.lua",
    dependencies = deps,
})
assert(type(bootstrap) == "string")
assert(bootstrap:find("luainstaller generated bootstrap", 1, true))

local chunk = assert(load(bootstrap, "@generated-runtime-bundle"))
local old_arg = _G.arg
_G.arg = { "generated.lua", "generated" }
local generated_output = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    generated_output[#generated_output + 1] = table.concat(parts, "\t")
end
chunk()
print = old_print
_G.arg = old_arg
assert(generated_output[1] == "hello generated")
assert(generated_output[2] == "entry=test/runtime_bundle/main.lua")

local single = cgen.generateBootstrap({
    entry = "test/single_file/01_hello_luainstaller.lua",
    dependencies = { scripts = {}, libraries = {} },
})
assert(assert(load(single, "@generated-single-file")))

print("runtime cgen ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "runtime cgen ok")
end
```

Call it at the bottom after `check_cli_contract()`:

```lua
check_runtime_cgen()
```

- [ ] **Step 4: Verify RED**

Run:

```sh
lua test/smoke_all.lua
```

Historical expectation: this failed when the runtime generator had not been
implemented yet. In the current tree, `src/cgen.lua` exists and
`lua test/smoke_all.lua` is expected to pass before packaging work is accepted.

- [ ] **Step 5: Commit failing tests**

```sh
git add test/runtime_bundle test/smoke_all.lua
git commit -m "test: add runtime cgen smoke coverage"
```

## Task 2: Runtime Module

**Files:**
- Modify: `src/runtime.lua`

- [ ] **Step 1: Implement `src/runtime.lua`**

Replace the empty file with:

```lua
--[[
Pure Lua bundle runtime for luainstaller.

Author:
    WaterRun
File:
    runtime.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

local function loaderTable()
    return package.searchers or package.loaders
end

function M.stripSource(source)
    source = tostring(source or "")
    if source:sub(1, 3) == "\239\187\191" then
        source = source:sub(4)
    end
    if source:sub(1, 2) == "#!" then
        local rest = source:match("^[^\n]*(\n?.*)$")
        source = rest or ""
        if source:sub(1, 1) == "\n" then
            source = source:sub(2)
        end
    end
    return source
end

local function loadPayloadSource(record, chunk_name)
    local source = M.stripSource(record.source or "")
    local loader, err = load(source, chunk_name or ("@" .. tostring(record.path or "bundle")), "t")
    if not loader then
        error({
            type = "LoadError",
            message = tostring(err),
            path = record.path,
        })
    end
    return loader
end

function M.install(payload)
    payload = payload or {}
    local modules = payload.modules or {}
    local searchers = loaderTable()
    local searcher

    searcher = function(module_name)
        local record = modules[module_name]
        if not record then
            return "\n\tno bundled module '" .. tostring(module_name) .. "'"
        end
        return loadPayloadSource(record, "@" .. tostring(record.path or module_name)), record.path
    end

    table.insert(searchers, 2, searcher)

    return function()
        for i = #searchers, 1, -1 do
            if searchers[i] == searcher then
                table.remove(searchers, i)
                break
            end
        end
    end
end

function M.run(payload, run_args)
    payload = payload or {}
    run_args = run_args or {}
    local entry = payload.entry
    if type(entry) ~= "table" or type(entry.source) ~= "string" then
        error({
            type = "InvalidPayloadError",
            message = "payload.entry.source is required",
        })
    end

    local uninstall = M.install(payload)
    local old_arg = _G.arg
    local runtime_arg = { [0] = entry.path or entry.id or "__entry__" }
    for i = 1, #run_args do
        runtime_arg[i] = run_args[i]
    end
    _G.arg = runtime_arg

    local ok, result = pcall(function()
        local entry_loader = loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))
        return entry_loader()
    end)

    _G.arg = old_arg
    uninstall()

    if not ok then
        error(result)
    end
    return result
end

return M
```

- [ ] **Step 2: Verify runtime syntax**

Run:

```sh
luac -p src/runtime.lua
```

Expected: PASS.

- [ ] **Step 3: Commit runtime module**

```sh
git add src/runtime.lua
git commit -m "feat: add pure Lua bundle runtime"
```

## Task 3: Cgen Module

**Files:**
- Create: `src/cgen.lua`
- Modify: `luainstaller-1.0.0-1.rockspec`

- [ ] **Step 1: Create `src/cgen.lua`**

Create the file with:

```lua
--[[
Lua bootstrap generation for luainstaller bundles.

Author:
    WaterRun
File:
    cgen.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

local function normalizePath(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function basename(path)
    path = normalizePath(path)
    return path:match("[^/]+$") or path
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        error({
            type = "ScriptNotFoundError",
            message = "Cannot read file: " .. tostring(path),
            path = path,
        })
    end
    local content = handle:read("*a")
    handle:close()
    return content or ""
end

local function quote(value)
    return string.format("%q", tostring(value or ""))
end

function M.moduleNameFromPath(path)
    path = normalizePath(path)
    if path:match("/init%.lua$") then
        return path:match("([^/]+)/init%.lua$") or "init"
    end
    local name = basename(path)
    return (name:gsub("%.lua$", ""))
end

function M.buildPayload(opts)
    opts = opts or {}
    if not opts.entry then
        error({
            type = "InvalidOptionsError",
            message = "entry is required",
        })
    end

    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local payload = {
        entry = {
            id = "__entry__",
            path = opts.entry,
            source = readFile(opts.entry),
        },
        modules = {},
    }

    for _, path in ipairs(dependencies.scripts or {}) do
        local module_name = opts.module_names and opts.module_names[path] or M.moduleNameFromPath(path)
        if payload.modules[module_name] then
            error({
                type = "DuplicateModuleError",
                message = "Duplicate generated module name: " .. module_name,
                module_name = module_name,
            })
        end
        payload.modules[module_name] = {
            path = path,
            source = readFile(path),
        }
    end

    return payload
end

local function emitPayload(payload)
    local lines = {}
    lines[#lines + 1] = "local payload = {"
    lines[#lines + 1] = "  entry = {"
    lines[#lines + 1] = "    id = " .. quote(payload.entry.id) .. ","
    lines[#lines + 1] = "    path = " .. quote(payload.entry.path) .. ","
    lines[#lines + 1] = "    source = " .. quote(payload.entry.source) .. ","
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "  modules = {"
    for name, record in pairs(payload.modules or {}) do
        lines[#lines + 1] = "    [" .. quote(name) .. "] = {"
        lines[#lines + 1] = "      path = " .. quote(record.path) .. ","
        lines[#lines + 1] = "      source = " .. quote(record.source) .. ","
        lines[#lines + 1] = "    },"
        lines[#lines + 1] = "  },"
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

local RUNTIME_SOURCE = [=[
local function stripSource(source)
  source = tostring(source or "")
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  if source:sub(1, 2) == "#!" then
    local rest = source:match("^[^\n]*(\n?.*)$")
    source = rest or ""
    if source:sub(1, 1) == "\n" then source = source:sub(2) end
  end
  return source
end

local function loaderTable()
  return package.searchers or package.loaders
end

local function loadPayloadSource(record, chunk_name)
  local loader, err = load(stripSource(record.source or ""), chunk_name or ("@" .. tostring(record.path or "bundle")), "t")
  if not loader then error(err) end
  return loader
end

local function install(payload)
  local modules = payload.modules or {}
  local searchers = loaderTable()
  local searcher
  searcher = function(module_name)
    local record = modules[module_name]
    if not record then return "\n\tno bundled module '" .. tostring(module_name) .. "'" end
    return loadPayloadSource(record, "@" .. tostring(record.path or module_name)), record.path
  end
  table.insert(searchers, 2, searcher)
  return function()
    for i = #searchers, 1, -1 do
      if searchers[i] == searcher then table.remove(searchers, i); break end
    end
  end
end

local function run(payload, run_args)
  local uninstall = install(payload)
  local old_arg = _G.arg
  local entry = payload.entry
  local runtime_arg = { [0] = entry.path or entry.id or "__entry__" }
  for i = 1, #(run_args or {}) do runtime_arg[i] = run_args[i] end
  _G.arg = runtime_arg
  local ok, result = pcall(function()
    return loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))()
  end)
  _G.arg = old_arg
  uninstall()
  if not ok then error(result) end
  return result
end
]=]

function M.generateBootstrap(opts)
    local payload = M.buildPayload(opts)
    local source = {}
    source[#source + 1] = "-- luainstaller generated bootstrap"
    source[#source + 1] = emitPayload(payload)
    source[#source + 1] = RUNTIME_SOURCE
    source[#source + 1] = "local run_args = {}"
    source[#source + 1] = "if arg then for i = 1, #arg do run_args[i] = arg[i] end end"
    source[#source + 1] = "return run(payload, run_args)"
    return table.concat(source, "\n")
end

return M
```

- [ ] **Step 2: Register runtime and cgen in rockspec**

Add to the `modules` table in `luainstaller-1.0.0-1.rockspec`:

```lua
["luainstaller.runtime"]  = "src/runtime.lua",
["luainstaller.cgen"]     = "src/cgen.lua",
```

- [ ] **Step 3: Verify GREEN**

Run:

```sh
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: PASS, including `runtime cgen ok`.

- [ ] **Step 4: Commit cgen module**

```sh
git add src/cgen.lua luainstaller-1.0.0-1.rockspec test/smoke_all.lua
git commit -m "feat: add Lua bootstrap generator"
```

## Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `README-zh.md`

- [ ] **Step 1: Update English README**

Add this paragraph under How It Works:

```markdown
The pure Lua runtime milestone is implemented: `luainstaller.runtime` can install
a bundled module searcher, and `luainstaller.cgen` can generate a Lua bootstrap
chunk for pure Lua payloads. This bootstrap is the Lua side that future C
launcher work will embed.
```

- [ ] **Step 2: Update Chinese README**

Add this paragraph under 工作原理:

```markdown
纯 Lua runtime 里程碑已实现：`luainstaller.runtime` 可以安装 bundled module
searcher，`luainstaller.cgen` 可以为纯 Lua payload 生成 Lua bootstrap chunk。
这段 bootstrap 是后续 C launcher 将要嵌入的 Lua 侧启动逻辑。
```

- [ ] **Step 3: Commit docs**

```sh
git add README.md README-zh.md
git commit -m "docs: document pure Lua runtime bootstrap"
```

## Task 5: Final Verification

**Files:**
- Read: current worktree

- [ ] **Step 1: Run syntax and smoke**

```sh
lua -v
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: Lua version prints, syntax passes, smoke prints `runtime cgen ok` and `all packaging-target samples passed comprehensive smoke audit`.

- [ ] **Step 2: Verify LuaRocks install includes new modules**

```sh
luarocks make --local luainstaller-1.0.0-1.rockspec
lua -e 'local runtime = require("luainstaller.runtime"); local cgen = require("luainstaller.cgen"); print(type(runtime.run), type(cgen.generateBootstrap))'
```

Expected: install succeeds and the Lua one-liner prints `function function`.

- [ ] **Step 3: Check worktree**

```sh
git status --short
git log --oneline -n 12
```

Expected: worktree clean after commits.
