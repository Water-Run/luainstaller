# Traceable Analyzer And Manifest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real analyzer trace records and manifest generation so `luai -t` and `luainstaller.bundle(opts)` expose the build-plan contract needed by the future bundler and launcher.

**Architecture:** Extend `src/analyzer.lua` in place with trace-aware resolution while preserving the existing `analyzeDependencies()` result shape. Add `src/manifest.lua` as a focused manifest constructor, then wire `src/init.lua` and `src/cli.lua` to use these richer results.

**Tech Stack:** Lua 5.4-compatible implementation, project smoke tests in `test/smoke_all.lua`, LuaRocks rockspec module installation.

---

## File Structure

- Modify `src/analyzer.lua`: candidate collection, trace records, `traceDependencies()`.
- Create `src/manifest.lua`: manifest construction, path normalization, stable hashes, duplicate destination checks.
- Modify `src/init.lua`: use analyzer trace path, build manifest in `bundle()`, expose structured manifest errors.
- Modify `src/cli.lua`: render richer trace lines.
- Modify `test/smoke_all.lua`: add trace and manifest contract checks.
- Modify `luainstaller-1.0.0-1.rockspec`: install `luainstaller.manifest`.
- Modify `README.md`, `README-zh.md`: document real trace records and manifest-bearing bundle planning.

## Task 1: Trace Contract Tests

**Files:**
- Modify: `test/smoke_all.lua`

- [ ] **Step 1: Add analyzer trace assertions**

Inside `check_api_contract()` in `test/smoke_all.lua`, after the existing `traced` assertions, add:

```lua
local function find_trace(items, requested)
    for _, item in ipairs(items) do
        if item.requested == requested then
            return item
        end
    end
    return nil
end

local model_trace = assert(find_trace(traced.trace, "model"))
assert(model_trace.requiring_file:match("student_management_system/main%.lua$"))
assert(type(model_trace.source_line) == "number")
assert(model_trace.classification == "lua")
assert(model_trace.selected_type == "lua")
assert(model_trace.selected_path:match("student_management_system/model%.lua$"))
assert(type(model_trace.candidates) == "table")
assert(#model_trace.candidates > 0)
assert(model_trace.reason == "resolved")

local firebird_trace = luainstaller.trace({
    entry = "test/firebird_web_sql/server.lua",
    max_deps = 250,
})
assert(firebird_trace.ok == true, firebird_trace.error and firebird_trace.error.message)
local optional_firebird = assert(find_trace(firebird_trace.trace, "luasql.firebird"))
assert(optional_firebird.optional == true)
assert(optional_firebird.classification == "missing")
assert(optional_firebird.reason == "optional-missing")
assert(type(optional_firebird.candidates) == "table")
```

- [ ] **Step 2: Verify RED**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL because current `trace()` records do not include `requiring_file`, `source_line`, `candidates`, or optional missing trace entries.

- [ ] **Step 3: Commit the failing trace test**

```sh
git add test/smoke_all.lua
git commit -m "test: add analyzer trace contract coverage"
```

## Task 2: Analyzer Trace Implementation

**Files:**
- Modify: `src/analyzer.lua`

- [ ] **Step 1: Add candidate builders to `ModuleResolver`**

Add methods after `getSearchedPaths()`:

```lua
function ModuleResolver:buildCandidates(module_name, from_script)
    local candidates = {}

    if self:isBuiltin(module_name) then
        return candidates
    end

    if module_name:sub(1, 2) == "./" or module_name:sub(1, 3) == "../" then
        local base_dir = pathParent(from_script)
        local target = normalizePath(base_dir .. "/" .. module_name)
        local ext = pathExtension(target)
        local lua_paths = {}
        local native_paths = {}

        if ext == ".lua" then
            lua_paths[#lua_paths + 1] = target
        elseif ext and NATIVE_EXTENSIONS[ext] then
            native_paths[#native_paths + 1] = target
        else
            lua_paths[#lua_paths + 1] = target .. ".lua"
            lua_paths[#lua_paths + 1] = target .. "/init.lua"
            native_paths[#native_paths + 1] = target .. (IS_WINDOWS and ".dll" or ".so")
            native_paths[#native_paths + 1] = target .. ".a"
            native_paths[#native_paths + 1] = target .. ".dylib"
        end

        for _, path in ipairs(lua_paths) do
            candidates[#candidates + 1] = { type = "lua", template = path, path = path }
        end
        for _, path in ipairs(native_paths) do
            candidates[#candidates + 1] = { type = "native", template = path, path = path }
        end
        return candidates
    end

    local module_path = module_name:gsub("%.", "/")
    for _, tpl in ipairs(self.lua_templates) do
        candidates[#candidates + 1] = {
            type = "lua",
            template = tpl,
            path = tpl:gsub("%?", module_path),
        }
    end
    for _, tpl in ipairs(self.native_templates) do
        candidates[#candidates + 1] = {
            type = "native",
            template = tpl,
            path = tpl:gsub("%?", module_path),
        }
    end
    return candidates
end

function ModuleResolver:inspect(module_name, from_script)
    local candidates = self:buildCandidates(module_name, from_script)

    if self:isBuiltin(module_name) then
        return {
            ok = true,
            type = "builtin",
            classification = "builtin",
            reason = "builtin",
            candidates = candidates,
        }
    end

    for _, candidate in ipairs(candidates) do
        if fileExists(candidate.path) then
            return {
                ok = true,
                type = candidate.type,
                path = resolvePath(candidate.path),
                classification = candidate.type,
                reason = "resolved",
                candidates = candidates,
            }
        end
    end

    return {
        ok = false,
        type = "missing",
        classification = "missing",
        reason = "missing",
        candidates = candidates,
        error = errors.moduleNotFound(module_name, from_script, self:getSearchedPaths()),
    }
end
```

- [ ] **Step 2: Use `inspect()` from `resolve()`**

Replace the body of `ModuleResolver:resolve()` with:

```lua
function ModuleResolver:resolve(module_name, from_script)
    local inspected = self:inspect(module_name, from_script)
    if inspected.ok then
        if inspected.type == "builtin" then
            return nil
        end
        return { type = inspected.type, path = inspected.path }
    end
    error(inspected.error)
end
```

- [ ] **Step 3: Add trace storage and helper to `DependencyAnalyzer`**

In `DependencyAnalyzer.new()`, add:

```lua
self.trace = {}
```

Add this method before `analyzeRecursive()`:

```lua
function DependencyAnalyzer:recordTrace(script_path, req, inspected)
    local item = {
        requiring_file = script_path,
        source_line = req.line,
        requested = req.name,
        optional = req.optional == true,
        candidates = inspected.candidates or {},
        selected_path = inspected.path,
        selected_type = inspected.type,
        classification = inspected.classification,
        reason = inspected.reason,
    }
    self.trace[#self.trace + 1] = item
    return item
end
```

- [ ] **Step 4: Replace recursive require resolution with trace-aware inspect**

Inside `DependencyAnalyzer:analyzeRecursive()`, replace the `pcall(self.resolver.resolve, ...)` block with:

```lua
local inspected = self.resolver:inspect(req.name, script_path)
self:recordTrace(script_path, req, inspected)

if inspected.ok then
    if inspected.type == "builtin" then
        goto continue_req
    end
    if inspected.type == "native" then
        if not self.native_set[inspected.path] then
            self.native_set[inspected.path] = true
            self.native_libs[#self.native_libs + 1] = inspected.path
        end
    elseif inspected.type == "lua" then
        if not child_seen[inspected.path] then
            child_seen[inspected.path] = true
            children[#children + 1] = inspected.path
            self:analyzeRecursive(inspected.path)
        end
    end
elseif req.optional then
    self.trace[#self.trace].reason = "optional-missing"
else
    error(inspected.error)
end
```

- [ ] **Step 5: Add public trace function**

After `analyzeDependencies()`, add:

```lua
function M.traceDependencies(entry_script, opts)
    opts = opts or {}
    if opts.manual_mode then
        return { scripts = {}, libraries = {}, trace = {} }
    end

    local da = DependencyAnalyzer.new(entry_script, opts.max_dependencies)
    local result = da:analyze()
    result.trace = da.trace
    return result
end
```

- [ ] **Step 6: Verify GREEN**

Run:

```sh
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: PASS through trace contract checks.

- [ ] **Step 7: Commit analyzer trace implementation**

```sh
git add src/analyzer.lua
git commit -m "feat: add traceable analyzer records"
```

## Task 3: Manifest Contract Tests

**Files:**
- Modify: `test/smoke_all.lua`

- [ ] **Step 1: Extend API contract checks for bundle manifest**

Inside `check_api_contract()`, after the existing `bundled` assertions, add:

```lua
assert(type(bundled.error.manifest) == "table")
local manifest = bundled.error.manifest
assert(manifest.version == 1)
assert(manifest.output.mode == "onedir")
assert(manifest.entry.source_path:match("student_management_system/main%.lua$"))
assert(manifest.entry.destination_path:match("^%.luai/lua/"))
assert(type(manifest.lua.version) == "string")
assert(type(manifest.lua.abi) == "string")
assert(type(manifest.platform.os) == "string")
assert(type(manifest.platform.arch) == "string")
assert(manifest.launcher.profile == "shared-lua")
assert(#manifest.modules.lua == 5)
assert(#manifest.modules.native == 1)
assert(#manifest.trace > 0)
assert(manifest.hash_algorithm == "fnv1a32")
assert(type(manifest.modules.lua[1].content_hash) == "string")
assert(#manifest.compatibility >= 4)
```

- [ ] **Step 2: Verify RED**

Run:

```sh
lua test/smoke_all.lua
```

Expected: FAIL because `bundle()` does not yet include `error.manifest`.

- [ ] **Step 3: Commit failing manifest test**

```sh
git add test/smoke_all.lua
git commit -m "test: add bundle manifest contract coverage"
```

## Task 4: Manifest Module

**Files:**
- Create: `src/manifest.lua`
- Modify: `luainstaller-1.0.0-1.rockspec`

- [ ] **Step 1: Create `src/manifest.lua`**

Create the file with:

```lua
--[[
Bundle manifest construction for luainstaller.

Author:
    WaterRun
File:
    manifest.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

local HASH_ALGORITHM = "fnv1a32"

local function normalizePath(path)
    path = tostring(path or ""):gsub("\\", "/")
    local prefix = ""
    if path:match("^//") then
        prefix = "//"
        path = path:sub(3)
    elseif path:match("^%a:/") then
        prefix = path:sub(1, 3)
        path = path:sub(4)
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        path = path:sub(2)
    end
    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = ".."
            end
        elseif segment ~= "." and segment ~= "" then
            parts[#parts + 1] = segment
        end
    end
    local result = prefix .. table.concat(parts, "/")
    if result == "" then
        return "."
    end
    return result
end

local function isAbsolutePath(path)
    return path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil
end

local function currentDirectory()
    local pipe = io.popen(package.config:sub(1, 1) == "\\" and "cd" or "pwd")
    if pipe then
        local dir = pipe:read("*l")
        pipe:close()
        if dir then
            return normalizePath(dir)
        end
    end
    return "."
end

local function absolutePath(path)
    path = normalizePath(path)
    if isAbsolutePath(path) then
        return path
    end
    return normalizePath(currentDirectory() .. "/" .. path)
end

local function basename(path)
    path = normalizePath(path)
    return path:match("[^/]+$") or path
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content or ""
end

local function fnv1a32(content)
    local hash = 2166136261
    for i = 1, #content do
        hash = hash ~ content:byte(i)
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function fileHash(path)
    local content = readFile(path)
    if not content then
        return nil
    end
    return fnv1a32(content)
end

local function luaInfo()
    local version = _VERSION or "Lua"
    local major, minor = version:match("Lua%s+(%d+)%.(%d+)")
    return {
        version = version,
        abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
    }
end

local function platformInfo()
    local sep = package.config:sub(1, 1)
    local os_name = sep == "\\" and "windows" or "unknown"
    local arch = "unknown"
    if sep ~= "\\" then
        local os_pipe = io.popen("uname -s 2>/dev/null")
        if os_pipe then
            local value = os_pipe:read("*l")
            os_pipe:close()
            if value and value ~= "" then
                os_name = value:lower()
            end
        end
        local arch_pipe = io.popen("uname -m 2>/dev/null")
        if arch_pipe then
            local value = arch_pipe:read("*l")
            arch_pipe:close()
            if value and value ~= "" then
                arch = value
            end
        end
    end
    return {
        os = os_name,
        arch = arch,
    }
end

local function fileEntry(path, destination_root)
    local source = absolutePath(path)
    return {
        source_path = source,
        destination_path = normalizePath(destination_root .. "/" .. basename(source)),
        content_hash = fileHash(source),
    }
end

local function appendFileEntries(target, paths, destination_root)
    for _, path in ipairs(paths or {}) do
        target[#target + 1] = fileEntry(path, destination_root)
    end
end

local function duplicateDestinationError(path, first_source, second_source)
    return {
        ok = false,
        error = {
            type = "DuplicateModuleError",
            message = string.format("Duplicate manifest destination: %s", path),
            destination_path = path,
            first_source = first_source,
            second_source = second_source,
        },
    }
end

local function checkDuplicateDestinations(manifest)
    local seen = {}
    local groups = { manifest.modules.lua, manifest.modules.native, manifest.modules.external }
    for _, group in ipairs(groups) do
        for _, item in ipairs(group) do
            local existing = seen[item.destination_path]
            if existing and existing ~= item.source_path then
                return duplicateDestinationError(item.destination_path, existing, item.source_path)
            end
            seen[item.destination_path] = item.source_path
        end
    end
    return nil
end

function M.build(opts)
    opts = opts or {}
    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local entry_path = absolutePath(opts.entry)
    local manifest = {
        version = 1,
        hash_algorithm = HASH_ALGORITHM,
        entry = {
            source_path = entry_path,
            destination_path = normalizePath(".luai/lua/" .. basename(entry_path)),
            content_hash = fileHash(entry_path),
        },
        output = {
            mode = opts.mode or "onedir",
            path = opts.out,
        },
        lua = luaInfo(),
        platform = platformInfo(),
        launcher = {
            profile = opts.launcher_profile or "shared-lua",
        },
        modules = {
            lua = {},
            native = {},
            external = {},
        },
        manual = {
            include = opts.include or {},
            exclude = opts.exclude or {},
            depscan = opts.depscan ~= false,
        },
        trace = opts.trace or {},
        compatibility = {
            "same OS",
            "same architecture",
            "same ABI",
            "same Lua ABI",
        },
    }

    appendFileEntries(manifest.modules.lua, dependencies.scripts, ".luai/lua")
    appendFileEntries(manifest.modules.native, dependencies.libraries, ".luai/native")

    local duplicate = checkDuplicateDestinations(manifest)
    if duplicate then
        return duplicate
    end

    return {
        ok = true,
        manifest = manifest,
    }
end

return M
```

- [ ] **Step 2: Add manifest to rockspec modules**

In `luainstaller-1.0.0-1.rockspec`, add:

```lua
["luainstaller.manifest"] = "src/manifest.lua",
```

- [ ] **Step 3: Verify syntax**

Run:

```sh
luac -p src/*.lua
```

Expected: PASS.

- [ ] **Step 4: Commit manifest module**

```sh
git add src/manifest.lua luainstaller-1.0.0-1.rockspec
git commit -m "feat: add bundle manifest module"
```

## Task 5: API And CLI Manifest Integration

**Files:**
- Modify: `src/init.lua`
- Modify: `src/cli.lua`

- [ ] **Step 1: Import manifest module in `src/init.lua`**

Add:

```lua
local manifest = require("luainstaller.manifest")
```

- [ ] **Step 2: Use analyzer trace path in `dependencyPlan()`**

Change the analyzer call to:

```lua
local ok, result = pcall(analyzer.traceDependencies, opts.entry, {
    max_dependencies = opts.max_deps or opts.max_dependencies or DEFAULT_MAX_DEPS,
})
```

Keep the rest of the function compatible; `scripts` and `libraries` remain present.

- [ ] **Step 3: Preserve trace in `analyze()` result**

Add `trace = dependencies.trace or {}` to the success result from `M.analyze()`.

- [ ] **Step 4: Replace `M.trace()` wrapper loop**

Change `M.trace()` to return the analyzer trace directly:

```lua
function M.trace(opts)
    local analyzed = M.analyze(opts)
    if not analyzed.ok then
        return analyzed
    end
    return {
        ok = true,
        action = "trace",
        entry = analyzed.entry,
        dependencies = analyzed.dependencies,
        trace = analyzed.trace or {},
    }
end
```

- [ ] **Step 5: Build manifest in `M.bundle()`**

Before returning `NotImplementedError`, call:

```lua
local built_manifest = manifest.build({
    entry = normalized.entry,
    mode = normalized.mode,
    out = normalized.out,
    dependencies = analyzed.dependencies,
    trace = analyzed.trace,
    include = normalized.include,
    exclude = normalized.exclude,
    depscan = normalized.depscan,
    launcher_profile = normalized.launcher_profile,
})
if not built_manifest.ok then
    return built_manifest
end
```

Then include `manifest = built_manifest.manifest` in the error details table.

- [ ] **Step 6: Update CLI trace rendering**

In `src/cli.lua`, update `renderTrace()` output line to:

```lua
io.write(string.format(
    "  %d) %s %s %s%s%s\n",
    i,
    item.classification or item.selected_type or "unknown",
    item.reason or "unknown",
    item.requested or "(unknown)",
    item.selected_path and " -> " or "",
    item.selected_path or ""
))
```

- [ ] **Step 7: Verify GREEN**

Run:

```sh
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: PASS, including trace and manifest contract checks.

- [ ] **Step 8: Commit API/CLI integration**

```sh
git add src/init.lua src/cli.lua test/smoke_all.lua
git commit -m "feat: expose trace manifest planning"
```

## Task 6: Documentation

**Files:**
- Modify: `README.md`
- Modify: `README-zh.md`

- [ ] **Step 1: Update English README**

In `README.md`, adjust the API table rows:

```markdown
| `luainstaller.trace(opts)` | implemented | Real analyzer trace records with requiring file, source line, candidates, classification, and reason. |
| `luainstaller.bundle(opts)` | planned | Returns `NotImplementedError` with `error.manifest` after validation. |
```

Add one sentence under How It Works:

```markdown
`bundle(opts)` now builds the manifest contract used by future onedir and launcher work before returning its current `NotImplementedError`.
```

- [ ] **Step 2: Update Chinese README**

In `README-zh.md`, mirror the same meaning:

```markdown
| `luainstaller.trace(opts)` | 已实现 | analyzer 真实 trace 记录，包含引用文件、源码行、候选项、分类和原因。 |
| `luainstaller.bundle(opts)` | 计划中 | 校验通过后返回带 `error.manifest` 的 `NotImplementedError`。 |
```

- [ ] **Step 3: Commit docs**

```sh
git add README.md README-zh.md
git commit -m "docs: document trace manifest planning"
```

## Task 7: Final Verification

**Files:**
- Read: current worktree

- [ ] **Step 1: Run syntax and smoke**

```sh
lua -v
luac -p src/*.lua
lua test/smoke_all.lua
```

Expected: Lua version prints, syntax passes, smoke prints `all packaging-target samples passed comprehensive smoke audit`.

- [ ] **Step 2: Run direct CLI trace and bundle planning**

```sh
lua src/cli.lua -t test/firebird_web_sql/server.lua --max-deps 250
lua src/cli.lua -c --onedir test/student_management_system/main.lua -o build/student-manager --max-deps 250
```

Expected: trace exits `0` and includes `optional-missing luasql.firebird`; bundle exits nonzero with `NotImplementedError`.

- [ ] **Step 3: Verify LuaRocks installation**

```sh
luarocks make --local luainstaller-1.0.0-1.rockspec
/home/waterrun/.luarocks/bin/luai -t test/student_management_system/main.lua --max-deps 250
```

Expected: LuaRocks install succeeds and installed `luai` prints trace records.

- [ ] **Step 4: Check worktree**

```sh
git status --short
git log --oneline -n 12
```

Expected: worktree clean after commits.
