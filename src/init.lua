--[[
Main public interface module for luainstaller.
Provides a unified API for dependency analysis, log
management, and build orchestration.

Author:
    WaterRun
File:
    init.lua
Date:
    2026-02-22
Updated:
    2026-02-22
]]


local bundler  = require("luainstaller.bundler")
local compat   = require("luainstaller.compat")
local logger   = require("luainstaller.logger")
local manifest = require("luainstaller.manifest")
local onefile  = require("luainstaller.onefile")
local discovery = require("luainstaller.discovery")
local result = require("luainstaller.result")


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
    COMPILATION_FAILED: Compiler returned non-zero exit code
    DUPLICATE_MODULE: Two files map to the same bundled destination
    INVALID_OPTIONS: Invalid API or CLI option table
    INVALID_OUTPUT: Unsafe or unsupported output path
    TOOLCHAIN: Missing compiler, headers, runtime, or target profile dependency
    UNSUPPORTED_PLATFORM: Target profile is not supported from this host
    FILESYSTEM: Required file operation failed
    DISCOVERY: Runtime dependency discovery failed
    LAUNCHER_GENERATION: Launcher source generation failed unexpectedly
    LUA_RUNTIME_NOT_FOUND: Linked Lua runtime could not be located
]]
M.ErrorTypes = {
    SCRIPT_NOT_FOUND      = "ScriptNotFoundError",
    CIRCULAR_DEPENDENCY   = "CircularDependencyError",
    DYNAMIC_REQUIRE       = "DynamicRequireError",
    DEPENDENCY_LIMIT      = "DependencyLimitExceededError",
    MODULE_NOT_FOUND      = "ModuleNotFoundError",
    COMPILATION_FAILED    = "CompilationFailedError",
    DUPLICATE_MODULE      = "DuplicateModuleError",
    INVALID_OPTIONS       = "InvalidOptionsError",
    INVALID_OUTPUT        = "InvalidOutputError",
    TOOLCHAIN             = "ToolchainError",
    UNSUPPORTED_PLATFORM  = "UnsupportedPlatformError",
    FILESYSTEM            = "FilesystemError",
    DISCOVERY             = "DiscoveryError",
    LAUNCHER_GENERATION   = "LauncherGenerationError",
    LUA_RUNTIME_NOT_FOUND = "LuaRuntimeNotFoundError",
}


local makeError = result.error

local function fileExists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function copySequence(list)
    if type(list) ~= "table" then
        return list
    end
    local copy = {}
    for i = 1, #list do
        copy[i] = list[i]
    end
    return copy
end

local ALLOWED_OPTIONS = {
    action = true,
    depscan = true,
    discovery_mode = true,
    entry = true,
    exclude = true,
    include = true,
    launcher_profile = true,
    lua_prefix = true,
    max_deps = true,
    mode = true,
    out = true,
    run_args = true,
    target_os = true,
    verbose = true,
}

local function normalizeOptions(opts)
    if type(opts) ~= "table" then
        return nil, makeError("InvalidOptionsError", "options must be a table")
    end
    for key in pairs(opts) do
        if not ALLOWED_OPTIONS[key] then
            return nil, makeError("InvalidOptionsError", "unknown option: " .. tostring(key), {
                option = key,
            })
        end
    end
    if type(opts.entry) ~= "string" or opts.entry == "" then
        return nil, makeError("InvalidOptionsError", "entry is required")
    end
    local normalized = {}
    for key, value in pairs(opts) do
        normalized[key] = value
    end
    normalized.include = copySequence(opts.include)
    normalized.exclude = copySequence(opts.exclude)
    normalized.run_args = copySequence(opts.run_args)
    return normalized
end

local function dependencyPlan(opts)
    return discovery.plan(opts)
end

local function validateBundleMode(mode)
    if mode == "onedir" or mode == "onefile" then
        return nil
    end
    return makeError("InvalidOptionsError", string.format("Unknown bundle mode: %s", tostring(mode)))
end

local function analyzeContext(opts, config)
    config = config or {}
    local normalized, err = normalizeOptions(opts)
    if not normalized then
        return nil, err
    end
    if config.default_mode and (normalized.mode == nil or normalized.mode == "") then
        normalized.mode = config.default_mode
    end
    if normalized.mode ~= nil then
        local mode_err = validateBundleMode(normalized.mode)
        if mode_err then
            return nil, mode_err
        end
    end
    if not fileExists(normalized.entry) then
        return nil, makeError("ScriptNotFoundError", string.format("Lua script not found: %s", normalized.entry), {
            script_path = normalized.entry,
        })
    end

    local dependencies, dep_err = dependencyPlan(normalized)
    if not dependencies then
        return nil, dep_err
    end

    return {
        options = normalized,
        entry = normalized.entry,
        dependencies = dependencies,
        trace = dependencies.trace or {},
    }
end

local function compatibilityDiagnostics(context)
    local normalized = context.options
    return compat.diagnose({
        entry = context.entry,
        mode = normalized.mode or "onedir",
        target_os = normalized.target_os or os.getenv("LUAI_TARGET_OS"),
        lua_prefix = normalized.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        launcher_profile = normalized.launcher_profile,
        dependencies = context.dependencies,
        trace = context.trace,
    })
end

--@description: Perform dependency analysis on a Lua entry script
--@param opts: table - Options table with entry
--@return: table - Structured result table
function M.analyze(opts)
    local context, err = analyzeContext(opts)
    if not context then
        return err
    end

    return {
        ok           = true,
        action       = "analyze",
        entry        = context.entry,
        dependencies = context.dependencies,
        trace        = context.trace,
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

--@description: Produce trace-oriented dependency diagnostics
--@param opts: table - Options table with entry
--@return: table - Structured trace result
function M.trace(opts)
    local context, err = analyzeContext(opts)
    if not context then
        return err
    end

    return {
        ok            = true,
        action        = "trace",
        entry         = context.entry,
        dependencies  = context.dependencies,
        trace         = context.trace,
        compatibility = compatibilityDiagnostics(context),
    }
end

function M.compatibility(opts)
    local context, err = analyzeContext(opts)
    if not context then
        return err
    end
    return {
        ok = true,
        action = "compatibility",
        entry = context.entry,
        compatibility = compatibilityDiagnostics(context),
    }
end

--@description: Validate bundle options and return the current planned result
--@param opts: table - Options table with entry
--@return: table - Structured bundle result or structured error
function M.bundle(opts)
    local context, err = analyzeContext(opts, { default_mode = "onedir" })
    if not context then
        return err
    end

    local normalized = context.options

    local built_manifest = manifest.build({
        entry = normalized.entry,
        mode = normalized.mode,
        out = normalized.out,
        dependencies = context.dependencies,
        trace = context.trace,
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
        dependencies = context.dependencies,
        trace = context.trace,
        manifest = built_manifest.manifest,
    }

    if normalized.mode == "onefile" then
        return onefile.bundleOnefile(bundle_opts)
    end

    return bundler.bundleOnedir(bundle_opts)
end

return M
