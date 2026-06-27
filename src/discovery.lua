--[[
Dependency discovery mode selection for luainstaller.

Author:
    WaterRun
File:
    discovery.lua
Date:
    2026-06-21
Updated:
    2026-06-21
]]

local analyzer = require("luainstaller.analyzer")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local M = {}

local DEFAULT_MAX_DEPS = 36

local normalizePath = path.normalize
local absolutePath = path.absolute
local dirname = path.dirname
local basename = path.basename
local commandOutput = process.output
local shellQuote = process.shellQuote

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

local function writeFile(path, content)
    local file = io.open(path, "wb")
    if not file then
        return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
            path = path,
        })
    end
    file:write(content or "")
    file:close()
    return nil
end

local function removeFile(path)
    os.remove(path)
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
        trace = result.trace or {},
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

local function traceScript(entry, output_path)
    local entry_dir = dirname(absolutePath(entry))
    return string.format([[
local output_path = %q
local entry = %q
local entry_dir = %q
local original_require = require
local seen = {}
local records = {}
local function q(value)
    return string.format("%%q", tostring(value or ""))
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
    local key = tostring(name) .. "\n" .. source
    if not seen[key] then
        seen[key] = true
        records[#records + 1] = { name = tostring(name), source = source }
    end
    return original_require(name)
end
arg = { [0] = entry }
for i = 1, select("#", ...) do
    arg[i] = select(i, ...)
end
local ok, err = pcall(function()
    local chunk = assert(loadfile(entry))
    return chunk()
end)
local out = assert(io.open(output_path, "wb"))
for _, record in ipairs(records) do
    out:write(q(record.name), "\t", q(record.source), "\n")
end
out:close()
if not ok then
    error(err)
end
]], output_path, entry, entry_dir)
end

local function parseTraceOutput(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, makeError("DiscoveryError", "Runtime require trace output was not written", {
            path = path,
        })
    end
    local records = {}
    for line in file:lines() do
        local name_q, source_q = line:match("^(.-)\t(.-)$")
        if name_q and source_q then
            local name_loader = load("return " .. name_q, "@require-trace-name", "t")
            local source_loader = load("return " .. source_q, "@require-trace-source", "t")
            if name_loader and source_loader then
                records[#records + 1] = {
                    name = name_loader(),
                    source = source_loader(),
                }
            end
        end
    end
    file:close()
    return records
end

local function runtimePlan(opts)
    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local script_path = normalizePath((os.getenv("TMPDIR") or "/tmp") .. "/luainstaller-require-trace-" .. stamp .. ".lua")
    local output_path = normalizePath((os.getenv("TMPDIR") or "/tmp") .. "/luainstaller-require-trace-" .. stamp .. ".txt")
    local err = writeFile(script_path, traceScript(opts.entry, output_path))
    if err then
        return nil, err
    end

    local args = {}
    for _, value in ipairs(opts.run_args or {}) do
        args[#args + 1] = shellQuote(value)
    end
    local command = table.concat({
        "lua",
        shellQuote(script_path),
        table.concat(args, " "),
    }, " ")

    local ok, output = commandOutput(command)
    removeFile(script_path)
    if not ok then
        removeFile(output_path)
        return nil, makeError("DiscoveryError", "Runtime require tracing failed", {
            command = command,
            output = output,
        })
    end

    local records, parse_err = parseTraceOutput(output_path)
    removeFile(output_path)
    if not records then
        return nil, parse_err
    end

    local resolver = analyzer.ModuleResolver.new(dirname(absolutePath(opts.entry)))
    local scripts = {}
    local libraries = {}
    local script_seen = {}
    local library_seen = {}
    local trace = {}

    for _, record in ipairs(records) do
        local inspected = resolver:inspect(record.name, record.source or opts.entry)
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
        }
        if inspected.ok and inspected.type == "lua" then
            if not script_seen[inspected.path] then
                script_seen[inspected.path] = true
                scripts[#scripts + 1] = inspected.path
            end
        elseif inspected.ok and inspected.type == "native" then
            if not library_seen[inspected.path] then
                library_seen[inspected.path] = true
                libraries[#libraries + 1] = inspected.path
            end
        elseif not inspected.ok then
            return nil, fromThrownError(inspected.error)
        end
    end

    return {
        scripts = scripts,
        libraries = libraries,
        trace = trace,
    }
end

function M.plan(opts)
    opts = opts or {}
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

    return applyManualInputs(raw, opts)
end

return M
