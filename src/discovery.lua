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

local function removeTree(path)
    commandOutput("rm -rf " .. shellQuote(path))
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

-- Decode a string.format("%q", ...) token without using load().
local function unquoteLuaString(quoted)
    if type(quoted) ~= "string" or #quoted < 2 or quoted:sub(1, 1) ~= '"' then
        return nil
    end
    local i = 2
    local out = {}
    while i <= #quoted do
        local c = quoted:sub(i, i)
        if c == '"' then
            if i == #quoted then
                return table.concat(out)
            end
            return nil
        end
        if c == "\\" then
            local n = quoted:sub(i + 1, i + 1)
            if n == "" then
                return nil
            end
            local simple = {
                a = "\a",
                b = "\b",
                f = "\f",
                n = "\n",
                r = "\r",
                t = "\t",
                v = "\v",
                ["\\"] = "\\",
                ['"'] = '"',
                ["'"] = "'",
                ["\n"] = "\n",
            }
            if simple[n] then
                out[#out + 1] = simple[n]
                i = i + 2
            elseif n:match("%d") then
                local digits = quoted:sub(i + 1):match("^(%d%d?%d?)")
                local value = tonumber(digits)
                if not value or value > 255 then
                    return nil
                end
                out[#out + 1] = string.char(value)
                i = i + 1 + #digits
            elseif n == "x" then
                local hex = quoted:sub(i + 2, i + 3)
                if not hex:match("^%x%x$") then
                    return nil
                end
                out[#out + 1] = string.char(tonumber(hex, 16))
                i = i + 4
            elseif n == "u" then
                local hex = quoted:sub(i + 2):match("^{(%x+)}")
                if not hex then
                    return nil
                end
                local code = tonumber(hex, 16)
                if not code or not utf8 or not utf8.char then
                    if code and code <= 0x7f then
                        out[#out + 1] = string.char(code)
                    else
                        return nil
                    end
                else
                    out[#out + 1] = utf8.char(code)
                end
                i = i + 3 + #hex + 1
            else
                return nil
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil
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
    local excludes = opts.exclude or {}

    for _, item in ipairs(result.trace or {}) do
        trace[#trace + 1] = item
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
        local normalized = normalizePath(path)
        if not fileExists(normalized) then
            return nil, makeError("ScriptNotFoundError", string.format("Included path not found: %s", normalized), {
                script_path = normalized,
            })
        end
        if not isExcluded(normalized, excludes) and not listContains(scripts, normalized) then
            scripts[#scripts + 1] = normalized
            if normalized:match("%.lua$") then
                trace[#trace + 1] = {
                    requiring_file = opts.entry,
                    source_line = 0,
                    requested = moduleNameFromLuaPath(normalized, opts.entry),
                    optional = false,
                    selected_path = normalized,
                    selected_type = "lua",
                    classification = "lua",
                    reason = "manual-include",
                    candidates = { normalized },
                }
            end
        end
    end

    return {
        scripts = scripts,
        libraries = libraries,
        trace = trace,
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
local seen = {}
local records = {}
local function q(value)
    return string.format("%%q", tostring(value or ""))
end
local function flush_records()
    local out = io.open(output_path, "wb")
    if not out then
        return
    end
    for _, record in ipairs(records) do
        out:write(q(record.name), "\t", q(record.source), "\n")
    end
    out:close()
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
    local record_index
    if not seen[key] then
        seen[key] = true
        records[#records + 1] = { name = tostring(name), source = source }
        record_index = #records
    end
    local result = table.pack(pcall(original_require, name))
    if not result[1] then
        if record_index then
            seen[key] = nil
            table.remove(records, record_index)
        end
        error(result[2], 0)
    end
    return table.unpack(result, 2, result.n)
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
            local name = unquoteLuaString(name_q)
            local source = unquoteLuaString(source_q)
            if name and source then
                records[#records + 1] = {
                    name = name,
                    source = source,
                }
            end
        end
    end
    file:close()
    return records
end

local function runtimePlan(opts)
    local work_dir, work_err = makePrivateWorkDir("require-trace")
    if not work_dir then
        return nil, work_err
    end
    local script_path = normalizePath(work_dir .. "/trace.lua")
    local output_path = normalizePath(work_dir .. "/trace.txt")
    local err = writeFile(script_path, traceScript(opts.entry, output_path))
    if err then
        removeTree(work_dir)
        return nil, err
    end

    local args = {}
    for _, value in ipairs(opts.run_args or {}) do
        args[#args + 1] = shellQuote(value)
    end
    local command = table.concat({
        shellQuote(luaInterpreter(opts)),
        shellQuote(script_path),
        table.concat(args, " "),
    }, " ")

    local ok, output = commandOutput(command)
    if not ok then
        removeTree(work_dir)
        return nil, makeError("DiscoveryError", "Runtime require tracing failed", {
            command = command,
            output = output,
        })
    end

    local records, parse_err = parseTraceOutput(output_path)
    removeTree(work_dir)
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
