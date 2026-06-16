--[[
Main public interface module for luainstaller.
Provides a unified API for dependency analysis, log
management, and build orchestration. Sub-modules are
loaded on demand where possible to keep startup fast.

Author:
    WaterRun
File:
    init.lua
Date:
    2026-02-22
Updated:
    2026-02-22
]]


local analyzer = require("luainstaller.analyzer")
local logger   = require("luainstaller.logger")


--[[
Public API module for luainstaller.
Re-exports essential functions from sub-modules and provides
convenience wrappers with simplified signatures.

Author:
    WaterRun
Module:
    luainstaller
]]
local M = {}


--@description: Semantic version string of the package
--@const: VERSION
M.VERSION = "1.0.0"

--@description: Package author name
--@const: AUTHOR
M.AUTHOR = "WaterRun"

--@description: Package author email address
--@const: EMAIL
M.EMAIL = "linzhangrun49@gmail.com"

--@description: Project homepage URL
--@const: URL
M.URL = "https://github.com/Water-Run/luainstaller"


--@description: Re-exported log level constants
M.LogLevel = logger.LogLevel

local DEFAULT_MAX_DEPS = 36


--[[
Error type identifier strings for programmatic error handling.
The type field of error tables thrown by luainstaller functions
matches one of these values.

Enum:
    ErrorTypes
Values:
    SCRIPT_NOT_FOUND: Entry or dependency script missing
    CIRCULAR_DEPENDENCY: Cyclic require chain detected
    DYNAMIC_REQUIRE: Non-literal require argument
    DEPENDENCY_LIMIT: Dependency count exceeded
    MODULE_NOT_FOUND: Required module not locatable
    COMPILATION_FAILED: Engine returned non-zero exit code
    ENGINE_NOT_FOUND: Unknown engine name specified
    OUTPUT_NOT_FOUND: Expected output file missing after compilation
]]
M.ErrorTypes = {
    SCRIPT_NOT_FOUND    = "ScriptNotFoundError",
    CIRCULAR_DEPENDENCY = "CircularDependencyError",
    DYNAMIC_REQUIRE     = "DynamicRequireError",
    DEPENDENCY_LIMIT    = "DependencyLimitExceededError",
    MODULE_NOT_FOUND    = "ModuleNotFoundError",
    COMPILATION_FAILED  = "CompilationFailedError",
    ENGINE_NOT_FOUND    = "EngineNotFoundError",
    OUTPUT_NOT_FOUND    = "OutputFileNotFoundError",
}


local function makeError(err_type, message, details)
    local err = {
        type    = err_type,
        message = message,
    }
    if details then
        for k, v in pairs(details) do
            err[k] = v
        end
    end
    return {
        ok    = false,
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
        scripts   = scripts,
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

--@description: Perform dependency analysis on a Lua entry script
--@param opts: table|string - Options table with entry, or legacy entry string
--@return: table - Structured result table
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
        ok           = true,
        action       = "analyze",
        entry        = normalized.entry,
        dependencies = dependencies,
    }
end

--@description: Retrieve operation logs with optional filtering
--@param opts: table|nil - Query options forwarded to logger.getLogs (limit, level, source, action, descending)
--@return: table - List of log entry tables
--@usage: local logs = luainstaller.getLogs({limit = 50, level = "error"})
function M.getLogs(opts)
    return logger.getLogs(opts)
end

--@description: Remove all stored operation logs
--@return: boolean - True when the operation succeeds
--@usage: luainstaller.clearLogs()
function M.clearLogs()
    return logger.clearLogs()
end

--@description: Return the names of all supported compilation engines
--@return: table - List of engine name strings
--@usage: local engines = luainstaller.getEngines()
function M.getEngines()
    return {
        "luastatic",
        "srlua",
        "winsrlua515",
        "winsrlua515-32",
        "winsrlua548",
        "linsrlua515",
        "linsrlua515-32",
        "linsrlua548",
    }
end

--@description: Produce trace-oriented dependency diagnostics
--@param opts: table|string - Options table with entry, or legacy entry string
--@return: table - Structured trace result
function M.trace(opts)
    local analyzed = M.analyze(opts)
    if not analyzed.ok then
        return analyzed
    end

    local trace = {}
    for _, path in ipairs(analyzed.dependencies.scripts) do
        trace[#trace + 1] = {
            requested     = basename(path):gsub("%.lua$", ""),
            selected_type = "lua",
            selected_path = path,
            reason        = "resolved",
        }
    end
    for _, path in ipairs(analyzed.dependencies.libraries) do
        trace[#trace + 1] = {
            requested     = basename(path),
            selected_type = "native",
            selected_path = path,
            reason        = "resolved",
        }
    end

    return {
        ok           = true,
        action       = "trace",
        entry        = analyzed.entry,
        dependencies = analyzed.dependencies,
        trace        = trace,
    }
end

--@description: Validate bundle options and return the current planned result
--@param opts: table|string - Options table with entry, or legacy entry string
--@return: table - Structured bundle result or structured error
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
        action       = "bundle",
        entry        = normalized.entry,
        mode         = normalized.mode,
        out          = normalized.out,
        dependencies = analyzed.dependencies,
    })
end

M.bundleToSinglefile = M.bundle
M.build = M.bundle

return M
