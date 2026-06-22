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
local bundler  = require("luainstaller.bundler")
local compat   = require("luainstaller.compat")
local logger   = require("luainstaller.logger")
local manifest = require("luainstaller.manifest")
local onefile  = require("luainstaller.onefile")
local require_engine = require("luainstaller.require_engine")


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

local function dependencyPlan(opts)
    return require_engine.plan(opts)
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
        trace        = dependencies.trace or {},
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

--@description: Return legacy compilation engine names kept for compatibility
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
    local normalized, err = normalizeOptions(opts)
    if not normalized then
        return err
    end

    local analyzed = M.analyze(normalized)
    if not analyzed.ok then
        return analyzed
    end

    return {
        ok            = true,
        action        = "trace",
        entry         = analyzed.entry,
        dependencies  = analyzed.dependencies,
        trace         = analyzed.trace or {},
        compatibility = compat.diagnose({
            entry = analyzed.entry,
            mode = normalized.mode or "onedir",
            target_os = normalized.target_os or os.getenv("LUAI_TARGET_OS"),
            lua_prefix = normalized.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
            launcher_profile = normalized.launcher_profile,
            dependencies = analyzed.dependencies,
            trace = analyzed.trace,
        }),
    }
end

function M.compatibility(opts)
    local normalized, err = normalizeOptions(opts)
    if not normalized then
        return err
    end
    local analyzed = M.analyze(normalized)
    if not analyzed.ok then
        return analyzed
    end
    return {
        ok = true,
        action = "compatibility",
        entry = analyzed.entry,
        compatibility = compat.diagnose({
            entry = analyzed.entry,
            mode = normalized.mode or "onedir",
            target_os = normalized.target_os or os.getenv("LUAI_TARGET_OS"),
            lua_prefix = normalized.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
            launcher_profile = normalized.launcher_profile,
            dependencies = analyzed.dependencies,
            trace = analyzed.trace,
        }),
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

    local bundle_opts = {
        entry = normalized.entry,
        out = normalized.out,
        target_os = normalized.target_os or os.getenv("LUAI_TARGET_OS"),
        lua_prefix = normalized.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        dependencies = analyzed.dependencies,
        trace = analyzed.trace,
        manifest = built_manifest.manifest,
    }

    if normalized.mode == "onefile" then
        return onefile.bundleOnefile(bundle_opts)
    end

    return bundler.bundleOnedir(bundle_opts)
end

M.bundleToSinglefile = M.bundle
M.build = M.bundle

return M
