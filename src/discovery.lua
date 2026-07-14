--[[
Dependency discovery mode selection for luainstaller.

Author:
    WaterRun
File:
    discovery.lua
Date:
    2026-06-21
Updated:
    2026-07-11
]]

local analyzer = require("luainstaller.analyzer")
local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local result = require("luainstaller.result")

local M = {}

local DEFAULT_MAX_DEPS = 36

local normalizePath = path.normalize
local absolutePath = path.absolute
local dirname = path.dirname
local basename = path.basename
local commandOutput = process.output
local shellQuote = process.shellQuote
local makeError = result.error

local function fromThrownError(err)
    return result.fromThrown(err)
end

local function sourceChanged(source_path, expected_hash, actual_hash, details)
    details = details or {}
    details.source_path = normalizePath(absolutePath(source_path))
    details.expected_hash = expected_hash
    details.actual_hash = actual_hash
    details.hash_algorithm = "sha256"
    return makeError(
        "SourceChangedError",
        "Source changed during dependency discovery: " .. tostring(source_path),
        details
    )
end

local function recordSourceHash(source_hashes, source_path, content)
    local canonical = normalizePath(absolutePath(source_path))
    local digest = hash.sha256(content)
    local previous = source_hashes[canonical]
    if previous and previous ~= digest then
        return nil, sourceChanged(canonical, previous, digest)
    end
    source_hashes[canonical] = digest
    return true
end

local function writeFile(path, content)
    local ok, write_err = fs.writeFile(path, content)
    if ok then return nil end
    return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
        path = path,
        cause = write_err,
    })
end

local function removeTree(path)
    local ok, output = commandOutput("rm -rf " .. shellQuote(path))
    if not ok then
        return makeError("FilesystemError", "Cannot remove runtime trace directory", {
            path = path,
            output = output,
        })
    end
    return nil
end

local function cleanupWorkDir(path_value, failure)
    local cleanup_err = path_value and removeTree(path_value) or nil
    if cleanup_err and failure and failure.error then
        failure.error.cleanup_error = cleanup_err.error
            and cleanup_err.error.message or tostring(cleanup_err)
        failure.error.cleanup_path = path_value
        return failure
    end
    return failure or cleanup_err
end

local function luaInterpreter(opts)
    opts = opts or {}
    if type(opts.lua) == "string" and opts.lua ~= "" then
        return opts.lua
    end
    local env_lua = os.getenv("LUAI_LUA")
    if env_lua and env_lua ~= "" then
        return env_lua
    end
    if type(arg) == "table" and type(arg[-1]) == "string" and arg[-1] ~= "" then
        return arg[-1]
    end
    return "lua"
end

local function validateLuaInterpreter(interpreter)
    local probe = table.concat({
        "local major, minor = tostring(_VERSION):match('Lua%s+(%d+)%.(%d+)')",
        "major, minor = tonumber(major), tonumber(minor)",
        "if major ~= 5 or not minor or minor < 1 or type(rawget(_G, 'jit')) == 'table' then "
            .. "io.stderr:write('expected official Lua 5.1+, got ', tostring(_VERSION), '\\n'); "
            .. "os.exit(42) end",
        "io.write(_VERSION)",
    }, ";")
    local ok, output = commandOutput(shellQuote(interpreter) .. " -e " .. shellQuote(probe))
    local major, minor = tostring(output):match("^Lua%s+(%d+)%.(%d+)%s*$")
    major, minor = tonumber(major), tonumber(minor)
    if not ok or major ~= 5 or not minor or minor < 1 then
        return makeError("ToolchainError", "Runtime discovery requires an official Lua 5.1+ interpreter", {
            interpreter = interpreter,
            output = output,
        })
    end
    return nil
end

local function listContains(list, value)
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

-- Match exact path, basename-only exclude, or path suffix with a "/" boundary.
-- Excluding "util.lua" must not match "myutil.lua".
local function isExcluded(file_path, excludes)
    local normalized = normalizePath(file_path)
    local name = basename(normalized)
    for i = 1, #excludes do
        local exclude = normalizePath(tostring(excludes[i]))
        if exclude ~= "" then
            if normalized == exclude then
                return true
            end
            if not exclude:find("/", 1, true) then
                if name == exclude then
                    return true
                end
            elseif normalized:sub(-(#exclude + 1)) == "/" .. exclude then
                return true
            end
        end
    end
    return false
end

local function moduleNameFromLuaPath(lua_path, entry)
    return path.moduleNameFromLuaPath(lua_path, entry)
end

local function decodeHex(encoded)
    if type(encoded) ~= "string" or #encoded % 2 ~= 0
        or encoded:find("[^0-9a-f]", 1) then
        return nil
    end
    return (encoded:gsub("(%x%x)", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

local function makePrivateWorkDir(prefix)
    local root = os.getenv("TMPDIR") or "/tmp"
    local max_attempts = 10
    for _ = 1, max_attempts do
        local stamp = tostring(os.time())
            .. tostring(os.clock()):gsub("%.", "")
            .. "-"
            .. tostring(math.random(100000, 999999))
        local dir = normalizePath(root .. "/luainstaller-" .. prefix .. "-" .. stamp)
        local ok, output = commandOutput("mkdir -m 700 " .. shellQuote(dir))
        if ok then
            return dir
        end
        -- Retry only when the path already exists (collision); other failures are fatal.
        local exists_ok = commandOutput("test -d " .. shellQuote(dir))
        if not exists_ok then
            return nil, makeError("FilesystemError", "Cannot create private temp directory", {
                path = dir,
                output = output,
            })
        end
    end
    return nil, makeError("FilesystemError", "Cannot create unique private temp directory after retries", {
        prefix = prefix,
    })
end

local function applyManualInputs(result, opts)
    local scripts = {}
    local libraries = {}
    local trace = {}
    local source_hashes = {}
    local excludes = opts.exclude or {}

    for source_path, digest in pairs(result.source_hashes or {}) do
        source_hashes[normalizePath(absolutePath(source_path))] = digest
    end

    for _, item in ipairs(result.trace or {}) do
        trace[#trace + 1] = item
    end

    local function addManualAlias(source_path, module_name)
        for _, item in ipairs(trace) do
            if item.selected_path == source_path and item.requested == module_name then
                return
            end
        end
        trace[#trace + 1] = {
            requiring_file = opts.entry,
            source_line = 0,
            requested = module_name,
            optional = false,
            selected_path = source_path,
            selected_type = "lua",
            classification = "lua",
            reason = "manual-include",
            candidates = { source_path },
        }
    end

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
        local normalized = absolutePath(path)
        if not normalized:lower():match("%.lua$") then
            return nil, makeError("InvalidOptionsError", string.format(
                "Manual include must be a Lua source file: %s",
                normalized
            ), {
                option = "include",
                script_path = normalized,
            })
        end
        local content, read_err = fs.readRegularFile(normalized)
        if content == nil then
            return nil, makeError("ScriptNotFoundError", string.format("Included path not found: %s", normalized), {
                script_path = normalized,
                cause = read_err,
            })
        end
        local syntax_ok, syntax_err = pcall(analyzer.validateSource, content, normalized)
        if not syntax_ok then
            return nil, fromThrownError(syntax_err)
        end
        local recorded, snapshot_err = recordSourceHash(source_hashes, normalized, content)
        if not recorded then
            return nil, snapshot_err
        end
        if not isExcluded(normalized, excludes) then
            if not listContains(scripts, normalized) then
                scripts[#scripts + 1] = normalized
            end
            local module_name = moduleNameFromLuaPath(normalized, opts.entry)
            addManualAlias(normalized, module_name)
            if normalized:lower():match("/init%.lua$") then
                addManualAlias(normalized, module_name .. ".init")
            end
        end
    end

    return {
        scripts = scripts,
        libraries = libraries,
        trace = trace,
        source_hashes = source_hashes,
    }
end

local function staticPlan(opts)
    local ok, result = pcall(analyzer.traceDependencies, opts.entry, {
        max_dependencies = opts.max_deps or DEFAULT_MAX_DEPS,
    })
    if not ok then
        return nil, fromThrownError(result)
    end
    return result
end

local function finalizeSourceSnapshots(plan, opts, initial_source_hashes)
    local source_hashes = plan.source_hashes or {}
    plan.source_hashes = source_hashes

    for source_path, initial_hash in pairs(initial_source_hashes or {}) do
        local canonical = normalizePath(absolutePath(source_path))
        local discovered_hash = source_hashes[canonical]
        if discovered_hash and discovered_hash ~= initial_hash then
            return nil, sourceChanged(canonical, initial_hash, discovered_hash)
        end
        source_hashes[canonical] = initial_hash
    end

    local selected = { opts.entry }
    for _, source_path in ipairs(plan.scripts or {}) do
        selected[#selected + 1] = source_path
    end
    for _, source_path in ipairs(plan.libraries or {}) do
        selected[#selected + 1] = source_path
    end

    local verified = {}
    for _, source_path in ipairs(selected) do
        local canonical = normalizePath(absolutePath(source_path))
        if not verified[canonical] then
            verified[canonical] = true
            local content, read_err = fs.readRegularFile(canonical)
            local expected_hash = source_hashes[canonical]
            if content == nil then
                return nil, sourceChanged(canonical, expected_hash, nil, {
                    cause = read_err,
                })
            end
            local actual_hash = hash.sha256(content)
            if expected_hash and expected_hash ~= actual_hash then
                return nil, sourceChanged(canonical, expected_hash, actual_hash)
            end
            source_hashes[canonical] = actual_hash
        end
    end
    return plan
end

-- Generated tracer for --discovery-mode runtime.
-- Limits: modules that capture require before this patch runs are not traced;
-- use --include for those. os.exit is wrapped so records are flushed first.
local function traceScript(entry, output_path)
    local entry_dir = dirname(absolutePath(entry))
    return string.format([[
local output_path = %q
local entry = %q
local entry_dir = %q
local original_require = require
local original_exit = os.exit
local original_load = load
local original_loadstring = loadstring
local original_setfenv = setfenv
local original_getfenv = getfenv
local original_string_dump = string.dump
local original_debug_getupvalue = debug.getupvalue
local original_debug_getinfo = debug.getinfo
local original_io_open = io.open
local original_global = _G
local recorded_names = {}
local inflight_names = {}
local records = {}
local active_records = {}
local wrapped_searchers = setmetatable({}, { __mode = "k" })
local completion = "LUAINSTALLER_TRACE_V4_COMPLETE"
local unpack_values = table.unpack or unpack
local function pack_values(...)
    return { n = select("#", ...), ... }
end
local function load_text(source, chunk_name, environment)
    if type(source) ~= "string" then return nil, "source must be a string" end
    if source:byte(1) == 27 then return nil, "binary chunks are not accepted" end
    if _VERSION == "Lua 5.1" then
        local loader, load_err = original_loadstring(source, chunk_name)
        if loader and environment then original_setfenv(loader, environment) end
        return loader, load_err
    end
    return original_load(source, chunk_name, "t", environment)
end
local function hex(value)
    return (tostring(value or ""):gsub(".", function(character)
        return string.format("%%02x", string.byte(character))
    end))
end
local function write_all(out, ...)
    local wrote, write_err = out:write(...)
    if not wrote then error(tostring(write_err or "trace write failed"), 0) end
end
local function flush_records()
    local out, open_err = io.open(output_path, "wb")
    if not out then error(tostring(open_err or "cannot open trace output"), 0) end
    local ok, write_err = pcall(function()
        for _, record in ipairs(records) do
            local snapshot_kind = record.snapshot_kind or "none"
            write_all(
                out,
                hex(record.name), "\t",
                hex(record.source), "\t",
                hex(record.loader_path), "\t",
                snapshot_kind, "\t",
                hex(record.loader_snapshot), "\t",
                record.cached and "cached" or "loaded", "\n"
            )
        end
        write_all(out, completion, "\n")
        local flushed, flush_err = out:flush()
        if not flushed then error(tostring(flush_err or "trace flush failed"), 0) end
    end)
    local closed, close_err = out:close()
    if not ok then error(write_err, 0) end
    if not closed then error(tostring(close_err or "trace close failed"), 0) end
end
local function discard_record(record)
    if record then
        for index = #records, 1, -1 do
            if records[index] == record then
                table.remove(records, index)
                return
            end
        end
    end
end
local function strip_source(source)
    source = tostring(source or "")
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    if source:sub(1, 2) == "#!" then
        local newline_start, newline_end = source:find("\r\n", 1, true)
        if not newline_start then newline_start, newline_end = source:find("[\r\n]") end
        if newline_start then source = "\n" .. source:sub(newline_end + 1) else source = "" end
    end
    return source
end
local function read_all(source_path)
    local input, open_err = original_io_open(source_path, "rb")
    if not input then return nil, open_err end
    local content, read_err = input:read("*a")
    local closed, close_err = input:close()
    if content == nil then return nil, read_err end
    if not closed then return nil, close_err end
    return content
end
local function capture_loader_snapshot(record, loader, loader_path)
    if type(record) ~= "table" then return end
    if type(loader_path) ~= "string" then
        error("LUAINSTALLER_RUNTIME_LOADER_UNVERIFIABLE: missing loader data", 0)
    end
    local extension = loader_path:lower():match("(%%.[^%%.]+)$")
    if extension ~= ".lua" then
        error("LUAINSTALLER_RUNTIME_LOADER_UNVERIFIABLE: unsupported loader data "
            .. loader_path, 0)
    end
    local snapshot, read_err = read_all(loader_path)
    if snapshot == nil then
        error("cannot snapshot runtime loader " .. loader_path .. ": " .. tostring(read_err), 0)
    end
    local rebuilt, rebuild_err = load_text(
        strip_source(snapshot),
        "@" .. loader_path,
        original_global
    )
    if not rebuilt then
        error("cannot validate runtime source " .. loader_path .. ": " .. tostring(rebuild_err), 0)
    end
    local loader_ok, loader_dump = pcall(original_string_dump, loader, true)
    local rebuilt_ok, rebuilt_dump = pcall(original_string_dump, rebuilt, true)
    if not loader_ok or not rebuilt_ok or loader_dump ~= rebuilt_dump then
        error("runtime source changed while its loader was created: " .. loader_path, 0)
    end
    local environment_ok
    local extra_upvalue
    if _VERSION == "Lua 5.1" then
        environment_ok = original_getfenv(loader) == original_global
        extra_upvalue = original_debug_getupvalue(loader, 1)
    else
        local environment_name, environment = original_debug_getupvalue(loader, 1)
        extra_upvalue = original_debug_getupvalue(loader, 2)
        environment_ok = environment_name == "_ENV" and environment == original_global
    end
    if not environment_ok or extra_upvalue ~= nil then
        error(
            "LUAINSTALLER_RUNTIME_LOADER_UNVERIFIABLE: non-reproducible loader environment "
                .. loader_path,
            0
        )
    end
    record.snapshot_kind = "lua"
    record.loader_snapshot = snapshot
end
local function wrap_searchers()
    local searchers = package.searchers or package.loaders
    for index = 1, #searchers do
        local original_searcher = searchers[index]
        if not wrapped_searchers[original_searcher] then
            local wrapper = function(name)
                local returned = pack_values(original_searcher(name))
                local active = active_records[#active_records]
                if type(active) == "table" and active.name == tostring(name)
                    and type(returned[1]) == "function" then
                    local loader_path = returned[2]
                    if type(loader_path) ~= "string" then
                        local loader_info = original_debug_getinfo(returned[1], "S") or {}
                        local loader_source = tostring(loader_info.source or "")
                        if loader_source:sub(1, 1) == "@" then
                            loader_path = loader_source:sub(2)
                        end
                    end
                    if type(loader_path) == "string" then
                        active.loader_path = loader_path
                    end
                    capture_loader_snapshot(active, returned[1], loader_path)
                end
                return unpack_values(returned, 1, returned.n)
            end
            wrapped_searchers[wrapper] = true
            searchers[index] = wrapper
        end
    end
end
package.path = entry_dir .. "/?.lua;" .. entry_dir .. "/?/init.lua;" .. package.path
package.cpath = table.concat({
    entry_dir .. "/?.so",
    entry_dir .. "/?/init.so",
    entry_dir .. "/?.dylib",
    entry_dir .. "/?/init.dylib",
    entry_dir .. "/?.dll",
    entry_dir .. "/?/init.dll",
}, ";") .. ";" .. package.cpath
require = function(name)
    local info = debug.getinfo(2, "S") or {}
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    else
        source = entry
    end
    local module_key = tostring(name)
    local loaded_value = package.loaded[name]
    local cached = loaded_value ~= nil and loaded_value ~= false
    local record
    -- A cached module has no loader data. Record its first observed call so
    -- the parent process can reject any unverifiable filesystem fallback.
    -- Calls cached from a load already seen by this tracer are already bound
    -- to the earlier loader snapshot and do not get recorded twice.
    if not inflight_names[module_key]
        and (not cached or not recorded_names[module_key]) then
        record = { name = module_key, source = source, cached = cached }
        records[#records + 1] = record
    end
    inflight_names[module_key] = (inflight_names[module_key] or 0) + 1
    active_records[#active_records + 1] = record or false
    local result = pack_values(pcall(function()
        wrap_searchers()
        return original_require(name)
    end))
    active_records[#active_records] = nil
    inflight_names[module_key] = inflight_names[module_key] - 1
    if inflight_names[module_key] == 0 then inflight_names[module_key] = nil end
    if not result[1] then
        discard_record(record)
        error(result[2], 0)
    end
    if record then
        recorded_names[module_key] = true
    end
    if record and type(result[3]) == "string" then
        record.loader_path = result[3]
    end
    return unpack_values(result, 2, result.n)
end
os.exit = function(code, close)
    flush_records()
    return original_exit(code, close)
end
arg = { [0] = entry }
for i = 1, select("#", ...) do
    arg[i] = select(i, ...)
end
local ok, err = pcall(function()
    local chunk = assert(loadfile(entry))
    return chunk()
end)
flush_records()
if not ok then
    error(err)
end
]], output_path, entry, entry_dir)
end

local function parseTraceOutput(path)
    local content, read_err = fs.readFile(path)
    if content == nil then
        return nil, makeError("DiscoveryError", "Runtime require trace output was not written", {
            path = path,
            cause = read_err,
        })
    end
    local records = {}
    local complete = false
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line == "LUAINSTALLER_TRACE_V4_COMPLETE" then
            if complete then
                return nil, makeError("DiscoveryError", "Runtime trace contains duplicate completion markers", {
                    path = path,
                })
            end
            complete = true
        elseif line ~= "" then
            if complete then
                return nil, makeError("DiscoveryError", "Runtime trace contains data after completion", {
                    path = path,
                })
            end
            local name_hex, source_hex, loader_hex, snapshot_kind, snapshot_hex, cache_state =
                line:match("^([0-9a-f]*)\t([0-9a-f]*)\t([0-9a-f]*)\t([a-z]+)\t([0-9a-f]*)\t([a-z]+)$")
            local name = decodeHex(name_hex)
            local source = decodeHex(source_hex)
            local loader_path = decodeHex(loader_hex)
            local loader_snapshot = decodeHex(snapshot_hex)
            if name == nil or source == nil or loader_path == nil
                or loader_snapshot == nil
                or (snapshot_kind ~= "lua" and snapshot_kind ~= "none")
                or (snapshot_kind == "none" and loader_snapshot ~= "")
                or (cache_state ~= "cached" and cache_state ~= "loaded") then
                return nil, makeError("DiscoveryError", "Runtime trace contains an invalid record", {
                    path = path,
                    record = line,
                })
            end
            records[#records + 1] = {
                name = name,
                source = source,
                loader_path = loader_path ~= "" and loader_path or nil,
                snapshot_kind = snapshot_kind,
                loader_snapshot = snapshot_kind ~= "none" and loader_snapshot or nil,
                cached = cache_state == "cached",
            }
        end
    end
    if not complete then
        return nil, makeError("DiscoveryError", "Runtime require trace output is incomplete", {
            path = path,
        })
    end
    return records
end

local function runtimePlan(opts)
    local interpreter = luaInterpreter(opts)
    local interpreter_err = validateLuaInterpreter(interpreter)
    if interpreter_err then
        return nil, interpreter_err
    end
    local work_dir, work_err = makePrivateWorkDir("require-trace")
    if not work_dir then
        return nil, work_err
    end
    local script_path = normalizePath(work_dir .. "/trace.lua")
    local output_path = normalizePath(work_dir .. "/trace.txt")
    local err = writeFile(script_path, traceScript(opts.entry, output_path))
    if err then
        return nil, cleanupWorkDir(work_dir, err)
    end

    local args = {}
    for _, value in ipairs(opts.run_args or {}) do
        args[#args + 1] = shellQuote(value)
    end
    local command = table.concat({
        shellQuote(interpreter),
        shellQuote(script_path),
        table.concat(args, " "),
    }, " ")

    local ok, output = commandOutput(command)
    if not ok then
        local message = "Runtime require tracing failed"
        if tostring(output):find(
            "LUAINSTALLER_RUNTIME_LOADER_UNVERIFIABLE:",
            1,
            true
        ) then
            message = "Runtime discovery requires a verified Lua source loader; use static discovery for other loaders"
        end
        local trace_err = makeError("DiscoveryError", message, {
            command = command,
            output = output,
        })
        return nil, cleanupWorkDir(work_dir, trace_err)
    end

    local records, parse_err = parseTraceOutput(output_path)
    local cleanup_err = cleanupWorkDir(work_dir, parse_err)
    if cleanup_err then
        return nil, cleanup_err
    end

    local resolver = analyzer.ModuleResolver.new(dirname(absolutePath(opts.entry)))
    local scripts = {}
    local libraries = {}
    local script_seen = {}
    local trace = {}
    local source_hashes = {}
    local max_dependencies = opts.max_deps or DEFAULT_MAX_DEPS

    local function addScript(source_path)
        if script_seen[source_path] then return true end
        if #scripts >= max_dependencies then
            return nil, makeError(
                "DependencyLimitExceededError",
                string.format(
                    "Dependency count (%d) exceeds limit (%d)",
                    #scripts + 1,
                    max_dependencies
                ),
                {
                    current_count = #scripts + 1,
                    limit = max_dependencies,
                }
            )
        end
        script_seen[source_path] = true
        scripts[#scripts + 1] = source_path
        return true
    end

    local function inspectRecord(record)
        if type(record.loader_path) == "string" and record.loader_path ~= "" then
            local selected_path = absolutePath(record.loader_path)
            local extension = selected_path:lower():match("(%.[^%.]+)$")
            local selected_type
            if extension == ".lua" and record.snapshot_kind == "lua" then
                selected_type = "lua"
            elseif fs.isRegularFile(selected_path)
                and (extension == ".so" or extension == ".dylib" or extension == ".dll") then
                selected_type = "native"
            elseif fs.isRegularFile(selected_path) and extension == ".lua" then
                selected_type = "lua"
            end
            if selected_type then
                return {
                    ok = true,
                    type = selected_type,
                    path = selected_path,
                    classification = selected_type,
                    reason = "runtime-loader-data",
                    candidates = {
                        {
                            type = selected_type,
                            template = record.loader_path,
                            path = selected_path,
                        },
                    },
                }
            end
        end
        return resolver:inspect(record.name, record.source or opts.entry)
    end

    for _, record in ipairs(records) do
        if record.cached then
            return nil, makeError(
                "DiscoveryError",
                "Runtime module was already loaded before tracing and has no verified loader snapshot; use static discovery",
                {
                    module_name = record.name,
                    cached_before_trace = true,
                }
            )
        end
        if record.snapshot_kind ~= "lua" or record.loader_snapshot == nil then
            return nil, makeError(
                "DiscoveryError",
                "Runtime require completed without a verified Lua source loader; use static discovery",
                {
                    module_name = record.name,
                    loader_path = record.loader_path,
                    snapshot_kind = record.snapshot_kind,
                }
            )
        end
        local inspected = inspectRecord(record)
        trace[#trace + 1] = {
            requiring_file = record.source or opts.entry,
            source_line = 0,
            requested = record.name,
            optional = false,
            candidates = inspected.candidates or {},
            selected_path = inspected.path,
            selected_type = inspected.type,
            classification = inspected.classification,
            reason = inspected.reason,
            loader_path = record.loader_path,
        }
        if inspected.ok
            and (inspected.type == "lua" or inspected.type == "native")
            and inspected.reason ~= "runtime-loader-data" then
            return nil, makeError(
                "DiscoveryError",
                "Runtime module has no filesystem loader snapshot; resolved fallback bytes were not executed",
                {
                    source_path = inspected.path,
                    module_name = record.name,
                    cached_before_trace = record.cached and true or false,
                }
            )
        end
        if inspected.ok and inspected.type == "lua" then
            if inspected.reason == "runtime-loader-data"
                and (record.snapshot_kind ~= "lua" or record.loader_snapshot == nil) then
                return nil, makeError(
                    "DiscoveryError",
                    "Runtime loader source could not be snapshotted before execution",
                    {
                        source_path = inspected.path,
                        module_name = record.name,
                    }
                )
            end
            if record.loader_snapshot ~= nil then
                local recorded, snapshot_err = recordSourceHash(
                    source_hashes,
                    inspected.path,
                    record.loader_snapshot
                )
                if not recorded then
                    return nil, snapshot_err
                end
            end
            local added, add_err = addScript(inspected.path)
            if not added then return nil, add_err end
        elseif inspected.ok and inspected.type == "native" then
            return nil, makeError(
                "DiscoveryError",
                "Runtime discovery cannot prove the exact bytes executed by a native loader; use static discovery",
                {
                    source_path = inspected.path,
                    module_name = record.name,
                }
            )
        elseif not inspected.ok then
            return nil, fromThrownError(inspected.error)
        end
    end

    return {
        scripts = scripts,
        libraries = libraries,
        trace = trace,
        source_hashes = source_hashes,
    }
end

function M.plan(opts, config)
    opts = opts or {}
    config = config or {}
    local mode = opts.discovery_mode
    if opts.depscan == false then
        mode = "manual"
    end
    mode = mode or "static"

    local raw
    local err
    if mode == "static" then
        raw, err = staticPlan(opts)
    elseif mode == "manual" then
        raw = { scripts = {}, libraries = {}, trace = {} }
    elseif mode == "runtime" then
        raw, err = runtimePlan(opts)
    else
        return nil, makeError("InvalidOptionsError", "Unknown discovery mode: " .. tostring(mode), {
            discovery_mode = mode,
        })
    end
    if not raw then
        return nil, err
    end

    local planned, manual_err = applyManualInputs(raw, opts)
    if not planned then
        return nil, manual_err
    end
    return finalizeSourceSnapshots(planned, opts, config.initial_source_hashes)
end

return M
