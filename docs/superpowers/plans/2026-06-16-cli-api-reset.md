# CLI/API Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy public entry shape with a truthful, testable `luai -a/-t/-c` CLI and structured `luainstaller.analyze/trace/bundle` API.

**Architecture:** Keep `src/analyzer.lua` as the dependency engine. Put structured public API behavior in `src/init.lua`, and make `src/cli.lua` a thin parser/renderer over that API while preserving existing log helpers. Use smoke tests to lock the new command contract before broad runtime work.

**Tech Stack:** Lua 5.4-compatible project code for the current workspace, roadmap-targeted Lua 5.5 documentation, LuaRocks rockspec, shell smoke tests.

---

## File Structure

- Modify `src/init.lua`: structured option-table API, result normalization, include/exclude handling, trace wrapper, planned bundle result.
- Modify `src/cli.lua`: help text, `-a/-t/-c` dispatch, option parsing, structured result rendering, compatibility aliases if cheap.
- Modify `test/smoke_all.lua`: add API and CLI reset smoke checks.
- Modify `luainstaller-1.0.0-1.rockspec`: install `luai`, keep only real modules, document Lua baseline without breaking local verification if Lua 5.5 is unavailable.
- Modify `README.md`, `README-zh.md`, `CODING-STYLE.txt`: align public contract and implementation status.
- Read-only reference: `docs/superpowers/specs/2026-06-16-cli-api-reset-design.md`, `ROAD_MAP.md`.

## Task 1: API Contract Smoke Tests

**Files:**
- Modify: `test/smoke_all.lua`
- Test: `test/smoke_all.lua`

- [ ] **Step 1: Add API reset checks to the smoke runner**

Insert this function after `check_analyzer_visibility()` in `test/smoke_all.lua`:

```lua
local function check_api_contract()
    local script = [[
package.path = "src/?.lua;src/?/init.lua;" .. package.path
local luainstaller = require("luainstaller")

local analyzed = luainstaller.analyze({
    entry = "test/student_management_system/main.lua",
    max_deps = 250,
})
assert(analyzed.ok == true, analyzed.error and analyzed.error.message)
assert(analyzed.action == "analyze")
assert(type(analyzed.dependencies) == "table")
assert(#analyzed.dependencies.scripts == 5)
assert(#analyzed.dependencies.libraries == 1)

local manual = luainstaller.analyze({
    entry = "test/student_management_system/main.lua",
    depscan = false,
    include = { "test/student_management_system/model.lua" },
    exclude = { "model.lua" },
})
assert(manual.ok == true, manual.error and manual.error.message)
assert(#manual.dependencies.scripts == 0)

local traced = luainstaller.trace({
    entry = "test/student_management_system/main.lua",
    max_deps = 250,
})
assert(traced.ok == true, traced.error and traced.error.message)
assert(traced.action == "trace")
assert(type(traced.trace) == "table")
assert(#traced.trace > 0)

local bundled = luainstaller.bundle({
    entry = "test/student_management_system/main.lua",
    mode = "onedir",
    out = "build/student-manager",
    max_deps = 250,
})
assert(bundled.ok == false)
assert(bundled.error.type == "NotImplementedError")

local missing = luainstaller.analyze({ entry = "test/no-such-file.lua" })
assert(missing.ok == false)
assert(missing.error.type == "ScriptNotFoundError")

print("api contract ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "api contract ok")
end
```

Then call it at the bottom:

```lua
check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()
```

- [ ] **Step 2: Run the API smoke test and verify it fails**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL before implementation because `luainstaller.analyze({ entry = ... })` does not return `{ ok = true, ... }`, and `trace` / `bundle` are missing.

- [ ] **Step 3: Commit the failing test**

```sh
git add test/smoke_all.lua
git commit -m "test: add public API contract smoke coverage"
```

## Task 2: Structured Public API

**Files:**
- Modify: `src/init.lua`
- Test: `test/smoke_all.lua`

- [ ] **Step 1: Replace legacy API wrappers with structured functions**

In `src/init.lua`, keep constants and log helpers, then replace the old `M.analyze`, `M.bundleToSinglefile`, and `M.build` functions with helpers and target API functions:

```lua
local DEFAULT_MAX_DEPS = 36

local function makeError(err_type, message, details)
    local err = {
        type = err_type,
        message = message,
    }
    if details then
        for k, v in pairs(details) do
            err[k] = v
        end
    end
    return {
        ok = false,
        error = err,
    }
end

local function fromThrownError(err)
    if type(err) == "table" then
        return makeError(err.type or "LuaInstallerError", err.message or tostring(err), err)
    end
    return makeError("LuaInstallerError", tostring(err))
end

local function fileExists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function basename(path)
    path = tostring(path or ""):gsub("\\", "/")
    return path:match("[^/]+$") or path
end

local function normalizeOptions(opts)
    if type(opts) == "string" then
        return { entry = opts }
    end
    if type(opts) ~= "table" then
        return nil, makeError("InvalidOptionsError", "options must be a table")
    end
    if type(opts.entry) ~= "string" or opts.entry == "" then
        return nil, makeError("InvalidOptionsError", "entry is required")
    end
    return opts
end

local function listContains(list, value)
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

local function isExcluded(path, excludes)
    local name = basename(path)
    for i = 1, #excludes do
        local exclude = tostring(excludes[i])
        if path == exclude or name == exclude or path:sub(-#exclude) == exclude then
            return true
        end
    end
    return false
end

local function applyManualInputs(result, opts)
    local scripts = {}
    local libraries = {}
    local excludes = opts.exclude or {}

    for _, path in ipairs(result.scripts or {}) do
        if not isExcluded(path, excludes) and not listContains(scripts, path) then
            scripts[#scripts + 1] = path
        end
    end

    for _, path in ipairs(result.libraries or {}) do
        if not isExcluded(path, excludes) and not listContains(libraries, path) then
            libraries[#libraries + 1] = path
        end
    end

    for _, path in ipairs(opts.include or {}) do
        if not fileExists(path) then
            return nil, makeError("ScriptNotFoundError", string.format("Included path not found: %s", path), {
                script_path = path,
            })
        end
        if not isExcluded(path, excludes) and not listContains(scripts, path) then
            scripts[#scripts + 1] = path
        end
    end

    return {
        scripts = scripts,
        libraries = libraries,
    }
end

local function dependencyPlan(opts)
    local raw
    if opts.depscan == false then
        raw = { scripts = {}, libraries = {} }
    else
        local ok, result = pcall(analyzer.analyzeDependencies, opts.entry, {
            max_dependencies = opts.max_deps or opts.max_dependencies or DEFAULT_MAX_DEPS,
        })
        if not ok then
            return nil, fromThrownError(result)
        end
        raw = result
    end

    local merged, err = applyManualInputs(raw, opts)
    if not merged then
        return nil, err
    end
    return merged
end

function M.analyze(opts)
    local normalized, err = normalizeOptions(opts)
    if not normalized then
        return err
    end
    if not fileExists(normalized.entry) then
        return makeError("ScriptNotFoundError", string.format("Lua script not found: %s", normalized.entry), {
            script_path = normalized.entry,
        })
    end

    local dependencies, dep_err = dependencyPlan(normalized)
    if not dependencies then
        return dep_err
    end

    return {
        ok = true,
        action = "analyze",
        entry = normalized.entry,
        dependencies = dependencies,
    }
end

function M.trace(opts)
    local analyzed = M.analyze(opts)
    if not analyzed.ok then
        return analyzed
    end

    local trace = {}
    for _, path in ipairs(analyzed.dependencies.scripts) do
        trace[#trace + 1] = {
            requested = basename(path):gsub("%.lua$", ""),
            selected_type = "lua",
            selected_path = path,
            reason = "resolved",
        }
    end
    for _, path in ipairs(analyzed.dependencies.libraries) do
        trace[#trace + 1] = {
            requested = basename(path),
            selected_type = "native",
            selected_path = path,
            reason = "resolved",
        }
    end

    return {
        ok = true,
        action = "trace",
        entry = analyzed.entry,
        dependencies = analyzed.dependencies,
        trace = trace,
    }
end

function M.bundle(opts)
    local normalized, err = normalizeOptions(opts)
    if not normalized then
        return err
    end

    normalized.mode = normalized.mode or "onedir"
    if normalized.mode ~= "onedir" and normalized.mode ~= "onefile" then
        return makeError("InvalidOptionsError", string.format("Unknown bundle mode: %s", tostring(normalized.mode)))
    end

    local analyzed = M.analyze(normalized)
    if not analyzed.ok then
        return analyzed
    end

    return makeError("NotImplementedError", string.format(
        "%s bundling is planned but not yet implemented",
        normalized.mode
    ), {
        action = "bundle",
        entry = normalized.entry,
        mode = normalized.mode,
        out = normalized.out,
        dependencies = analyzed.dependencies,
    })
end
```

- [ ] **Step 2: Run syntax checks**

Run:

```sh
luac -p src/*.lua
```

Expected: PASS with no output.

- [ ] **Step 3: Run smoke tests and verify API checks pass or expose analyzer-only failures**

Run:

```sh
lua test/smoke_all.lua
```

Expected after this task: API contract should pass when reached. If the earlier analyzer visibility check still fails, inspect the thrown table error before changing API behavior.

- [ ] **Step 4: Commit the API implementation**

```sh
git add src/init.lua
git commit -m "feat: add structured public API"
```

## Task 3: CLI Contract Smoke Tests

**Files:**
- Modify: `test/smoke_all.lua`
- Test: `test/smoke_all.lua`

- [ ] **Step 1: Add CLI reset checks**

Insert this function after `check_api_contract()`:

```lua
local function check_cli_contract()
    local lua_path = "LUA_PATH='src/?.lua;src/?/init.lua;;'"

    local help = run(lua_path .. " lua src/cli.lua --help")
    assert_contains(help, "luai -a <entry.lua>")
    assert_contains(help, "luai -t <entry.lua>")
    assert_contains(help, "luai -c <entry.lua>")

    local analyzed = run(lua_path .. " lua src/cli.lua -a test/student_management_system/main.lua --max-deps 250")
    assert_contains(analyzed, "success.")
    assert_contains(analyzed, "script(s)")
    assert_contains(analyzed, "library(ies)")

    local traced = run(lua_path .. " lua src/cli.lua -t test/student_management_system/main.lua --max-deps 250")
    assert_contains(traced, "trace.")
    assert_contains(traced, "resolved")

    local bundled = run(lua_path .. " lua src/cli.lua -c --onedir test/student_management_system/main.lua -o build/student-manager --max-deps 250", {
        expect_failure = true,
    })
    assert_contains(bundled, "NotImplementedError")
    assert_contains(bundled, "onedir bundling is planned")

    print("cli contract ok")
end
```

Then call it at the bottom:

```lua
check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()
check_cli_contract()
```

- [ ] **Step 2: Run the CLI smoke test and verify it fails**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL because `src/cli.lua` does not yet recognize `-a`, `-t`, or `-c`.

- [ ] **Step 3: Commit the failing CLI test**

```sh
git add test/smoke_all.lua
git commit -m "test: add luai CLI contract smoke coverage"
```

## Task 4: `luai -a/-t/-c` CLI

**Files:**
- Modify: `src/cli.lua`
- Test: `test/smoke_all.lua`

- [ ] **Step 1: Update help and imports**

At the top of `src/cli.lua`, add the public API import:

```lua
local luainstaller = require("luainstaller")
```

Replace `HELP_MESSAGE` with target help:

```lua
local HELP_MESSAGE = string.format([=[
luai - Package Lua projects into same-environment executables

Usage:
    luai --help
    luai --version
    luai -a <entry.lua> [options]
    luai -t <entry.lua> [options]
    luai -c <entry.lua> [options]

Actions:
  -a <entry.lua>
      Analyze dependencies.

  -t <entry.lua>
      Trace dependency resolution decisions.

  -c <entry.lua>
      Plan a bundle. --onedir is the default output mode. Actual bundling is
      still being implemented.

Options:
  --onedir              Select directory bundle mode (default)
  --onefile             Select single-file bundle mode (planned)
  -o, --out <path>      Output path for bundle actions
  --include <path>      Include an extra Lua file; repeatable
  --exclude <path>      Exclude a dependency by path or basename; repeatable
  --no-depscan          Disable automatic dependency scanning
  --max-deps <n>        Maximum dependency count (default: 36)
  --verbose             Print more detail

Compatibility:
  The first runtime promise is same OS, same architecture, same ABI, and same
  Lua ABI. Generated runtime launchers are not available in this milestone.

Visit: %s
]=], PROJECT_URL)
```

- [ ] **Step 2: Add option parsing helpers**

Add these helpers before command handlers:

```lua
local function newOptions()
    return {
        include = {},
        exclude = {},
        depscan = true,
        mode = "onedir",
        max_deps = DEFAULT_MAX_DEPS,
        verbose = false,
    }
end

local function parsePositiveInteger(value, option_name)
    local number = tonumber(value)
    if not number or number <= 0 or number ~= math.floor(number) then
        return nil, string.format("%s must be a positive integer", option_name)
    end
    return number
end

local function parseActionOptions(parser, action, first_entry)
    local opts = newOptions()
    opts.action = action
    opts.entry = first_entry

    while parser:hasNext() do
        local arg = parser:consume()
        if arg == "--onedir" then
            opts.mode = "onedir"
        elseif arg == "--onefile" then
            opts.mode = "onefile"
        elseif arg == "-o" or arg == "--out" then
            opts.out = parser:consumeValue(arg)
        elseif arg == "--include" then
            opts.include[#opts.include + 1] = parser:consumeValue(arg)
        elseif arg == "--exclude" then
            opts.exclude[#opts.exclude + 1] = parser:consumeValue(arg)
        elseif arg == "--no-depscan" then
            opts.depscan = false
        elseif arg == "--max-deps" then
            local number, err = parsePositiveInteger(parser:consumeValue(arg), arg)
            if not number then
                return nil, err
            end
            opts.max_deps = number
        elseif arg == "--verbose" then
            opts.verbose = true
        elseif not opts.entry and arg:sub(1, 1) ~= "-" then
            opts.entry = arg
        else
            return nil, string.format("Unknown option for %s: %s", action, arg)
        end
    end

    if not opts.entry then
        return nil, string.format("%s requires an entry script", action)
    end

    return opts
end
```

- [ ] **Step 3: Add renderers and action command handlers**

Add:

```lua
local function printStructuredError(result)
    local err = result and result.error or {}
    local err_type = err.type or "LuaInstallerError"
    local message = err.message or "operation failed"
    printError(string.format("%s: %s", err_type, message))
end

local function renderDependencySummary(result)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    io.write("success.\n")
    io.write(string.format("%s\n", result.entry))
    io.write(string.format("%d script(s), %d library(ies)\n", #deps.scripts, #deps.libraries))
    for i, path in ipairs(deps.scripts) do
        io.write(string.format("  script %d: %s\n", i, path))
    end
    for i, path in ipairs(deps.libraries) do
        io.write(string.format("  library %d: %s\n", i, path))
    end
end

local function renderTrace(result)
    io.write("trace.\n")
    io.write(string.format("%s\n", result.entry))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "  %d) %s %s %s\n",
            i,
            item.selected_type or "unknown",
            item.reason or "unknown",
            item.selected_path or "(no path)"
        ))
    end
end

local function cmdAction(parser, action, first_entry)
    local opts, err = parseActionOptions(parser, action, first_entry)
    if not opts then
        printError(err)
        return 1
    end

    local result
    if action == "analyze" then
        result = luainstaller.analyze(opts)
        if result.ok then
            renderDependencySummary(result)
            return 0
        end
    elseif action == "trace" then
        result = luainstaller.trace(opts)
        if result.ok then
            renderTrace(result)
            return 0
        end
    elseif action == "bundle" then
        result = luainstaller.bundle(opts)
        if result.ok then
            io.write("success.\n")
            return 0
        end
    end

    printStructuredError(result)
    return 1
end
```

- [ ] **Step 4: Dispatch target flags from `M.main`**

In `M.main`, before legacy command dispatch, add:

```lua
if command == "-a" then
    return cmdAction(parser, "analyze")
end

if command == "-t" then
    return cmdAction(parser, "trace")
end

if command == "-c" then
    return cmdAction(parser, "bundle")
end
```

Optionally map legacy commands to the new API without showing them as primary help:

```lua
if command == "analyze" then
    return cmdAction(parser, "analyze")
end

if command == "build" then
    return cmdAction(parser, "bundle")
end
```

Update the unknown-command hint:

```lua
printHint("Run 'luai --help' for usage information")
```

- [ ] **Step 5: Run CLI contract checks**

Run:

```sh
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: CLI contract checks pass unless an existing analyzer visibility failure appears first.

- [ ] **Step 6: Commit the CLI implementation**

```sh
git add src/cli.lua
git commit -m "feat: add luai action flag CLI"
```

## Task 5: Fix Analyzer Smoke Baseline If Needed

**Files:**
- Modify: `src/analyzer.lua` only if the failure is inside analyzer behavior.
- Modify: `test/smoke_all.lua` only if expected counts are stale and direct inspection proves the analyzer output is correct.
- Test: `test/smoke_all.lua`

- [ ] **Step 1: Reproduce the analyzer failure with readable errors**

Run:

```sh
lua -e 'local analyzer = dofile("src/analyzer.lua"); local entries = {"test/student_management_system/main.lua","test/firebird_web_sql/server.lua","test/savinglua/main.lua","test/ltokei/main.lua"}; for _, entry in ipairs(entries) do local ok, result = pcall(analyzer.analyzeDependencies, entry, { max_dependencies = 250 }); if ok then print(entry, #result.scripts, #result.libraries) else print(entry, result.type, result.message) end end'
```

Expected: Each target either prints dependency counts or a structured error type and message.

- [ ] **Step 2: Decide the fix from evidence**

If the error is a real unresolved optional dependency from a sample, update the sample or analyzer optional handling. If the analyzer returns a count different from `test/smoke_all.lua` while direct sample dependencies prove the new count is correct, update the expected count. Do not weaken the check to "anything passes".

- [ ] **Step 3: Apply the narrow fix**

Use one of these exact patterns:

For stale expected counts in `test/smoke_all.lua`, change only the table values in `entries`:

```lua
local entries = {
    ["test/student_management_system/main.lua"] = { scripts = 5, libraries = 1 },
    ["test/firebird_web_sql/server.lua"] = { scripts_min = 17, libraries_min = 2 },
    ["test/savinglua/main.lua"] = { scripts = 1, libraries = 2 },
    ["test/ltokei/main.lua"] = { scripts = 3, libraries = 1 },
}
```

For a missing optional require in analyzer, add a targeted condition near the resolver or require loop that records the skipped optional dependency without failing. Keep the full failure for ordinary `require`.

- [ ] **Step 4: Verify the baseline**

Run:

```sh
lua test/smoke_all.lua
```

Expected: PASS through analyzer visibility, API, and CLI checks.

- [ ] **Step 5: Commit the baseline fix**

```sh
git add src/analyzer.lua test/smoke_all.lua
git commit -m "fix: restore smoke analyzer baseline"
```

## Task 6: Packaging Metadata And Docs

**Files:**
- Modify: `luainstaller-1.0.0-1.rockspec`
- Modify: `README.md`
- Modify: `README-zh.md`
- Modify: `CODING-STYLE.txt`
- Test: `luarocks make luainstaller-1.0.0-1.rockspec`

- [ ] **Step 1: Update rockspec executable name**

In `luainstaller-1.0.0-1.rockspec`, change:

```lua
install = {
    bin = {
        ["luai"] = "src/cli.lua",
    },
},
```

Keep `modules` limited to files that exist:

```lua
modules = {
    ["luainstaller"]          = "src/init.lua",
    ["luainstaller.logger"]   = "src/logger.lua",
    ["luainstaller.analyzer"] = "src/analyzer.lua",
    ["luainstaller.cli"]      = "src/cli.lua",
},
```

- [ ] **Step 2: Update README command examples**

In `README.md`, replace the CLI section with examples using:

```sh
luai --help
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c --onedir test/student_management_system/main.lua -o build/student-manager
```

State that `-c` currently validates and plans bundling but returns
`NotImplementedError` until the onedir bundler milestone is implemented.

- [ ] **Step 3: Mirror the README updates in Chinese**

In `README-zh.md`, use:

```sh
luai --help
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c --onedir test/student_management_system/main.lua -o build/student-manager
```

State that `-c` 当前只完成参数校验和打包规划，真实 onedir 输出仍在后续阶段实现。

- [ ] **Step 4: Update coding style baseline**

In `CODING-STYLE.txt`, replace the Lua compatibility line with:

```text
- The roadmap baseline is Lua 5.5.0. During the transition, keep code runnable
  under the repository's current verification interpreter unless a change
  explicitly requires Lua 5.5 features.
```

- [ ] **Step 5: Verify LuaRocks metadata**

Run:

```sh
luarocks make luainstaller-1.0.0-1.rockspec
```

Expected: PASS if LuaRocks is installed and the local Lua version satisfies the rockspec. If Lua 5.5 is not locally available, keep the dependency compatible with local verification and document the roadmap baseline in docs.

- [ ] **Step 6: Commit docs and metadata**

```sh
git add luainstaller-1.0.0-1.rockspec README.md README-zh.md CODING-STYLE.txt
git commit -m "docs: align CLI reset documentation"
```

## Task 7: Final Verification

**Files:**
- Read: current worktree
- Test: full milestone command set

- [ ] **Step 1: Run syntax verification**

```sh
lua -v
luac -p src/*.lua
```

Expected: Lua version prints; syntax command exits `0`.

- [ ] **Step 2: Run full smoke audit**

```sh
lua test/smoke_all.lua
```

Expected: prints:

```text
all packaging-target samples passed comprehensive smoke audit
```

- [ ] **Step 3: Run direct CLI checks**

```sh
LUA_PATH='src/?.lua;src/?/init.lua;;' lua src/cli.lua --help
LUA_PATH='src/?.lua;src/?/init.lua;;' lua src/cli.lua -a test/student_management_system/main.lua --max-deps 250
LUA_PATH='src/?.lua;src/?/init.lua;;' lua src/cli.lua -t test/student_management_system/main.lua --max-deps 250
LUA_PATH='src/?.lua;src/?/init.lua;;' lua src/cli.lua -c --onedir test/student_management_system/main.lua -o build/student-manager --max-deps 250
```

Expected: help/analyze/trace exit `0`; compile planning exits nonzero with `NotImplementedError`.

- [ ] **Step 4: Run LuaRocks build**

```sh
luarocks make luainstaller-1.0.0-1.rockspec
```

Expected: PASS, or record the exact missing tool/version if the environment cannot run LuaRocks.

- [ ] **Step 5: Review worktree and summarize**

```sh
git status --short
git log --oneline -n 8
```

Expected: worktree is clean after commits, with this plan and implementation commits visible.
