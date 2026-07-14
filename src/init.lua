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
    2026-07-11
]]


local analyzer = require("luainstaller.analyzer")
local bundler  = require("luainstaller.bundler")
local compat   = require("luainstaller.compat")
local fs       = require("luainstaller.fs")
local hash     = require("luainstaller.hash")
local logger   = require("luainstaller.logger")
local manifest = require("luainstaller.manifest")
local onefile  = require("luainstaller.onefile")
local path     = require("luainstaller.path")
local platform = require("luainstaller.platform")
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
    LUA_SYNTAX: Entry or dependency contains invalid Lua syntax
    SOURCE_CHANGED: Source bytes changed after the manifest snapshot
    INVALID_MANIFEST: Manifest source or hash metadata is invalid
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
    LUA_SYNTAX            = "LuaSyntaxError",
    SOURCE_CHANGED        = "SourceChangedError",
    INVALID_MANIFEST      = "InvalidManifestError",
}


local makeError = result.error

local function invalidOption(option, message)
    return makeError("InvalidOptionsError", message or ("invalid option: " .. tostring(option)), {
        option = option,
    })
end

local function normalizeSequenceOption(opts, key)
    local value = opts[key]
    if value == nil then
        return {}
    end
    if type(value) ~= "table" then
        return nil, invalidOption(key, key .. " must be a list of strings")
    end
    local copy = {}
    for i, item_value in ipairs(value) do
        if type(item_value) ~= "string" then
            return nil, invalidOption(key, key .. " entries must be strings")
        end
        if item_value:find("\0", 1, true) then
            return nil, invalidOption(key, key .. " entries must not contain NUL bytes")
        end
        copy[i] = item_value
    end
    for item_key in pairs(value) do
        if type(item_key) ~= "number"
            or item_key < 1
            or item_key ~= math.floor(item_key)
            or item_key > #copy then
            return nil, invalidOption(key, key .. " must be a sequence")
        end
    end
    return copy
end

local function validateOptionalString(opts, key)
    local value = opts[key]
    if value ~= nil and type(value) ~= "string" then
        return invalidOption(key, key .. " must be a string")
    end
    if type(value) == "string" and value:find("\0", 1, true) then
        return invalidOption(key, key .. " must not contain NUL bytes")
    end
    return nil
end

local function validateOptionalBoolean(opts, key)
    local value = opts[key]
    if value ~= nil and type(value) ~= "boolean" then
        return invalidOption(key, key .. " must be a boolean")
    end
    return nil
end

local function validateNotDriveRelative(value, key)
    if type(value) == "string" and path.isDriveRelative(value) then
        return invalidOption(key, key .. " must not use a drive-relative path")
    end
    return nil
end

local function validateMaxDeps(opts)
    local value = opts.max_deps
    if value == nil then
        return nil
    end
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge
        or value < 1 or value ~= math.floor(value) then
        return invalidOption("max_deps", "max_deps must be a finite positive integer")
    end
    return nil
end

local function validateTargetOs(opts)
    local value = opts.target_os
    if value == nil or value == "" then value = os.getenv("LUAI_TARGET_OS") end
    local profile, profile_err = platform.profile({
        target_os = value,
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    })
    if not profile then
        return profile_err
    end
    return nil
end

local function validateLauncherProfile(opts)
    local value = opts.launcher_profile
    if value == nil or value == "" then return nil end
    local profile = platform.profile({
        target_os = opts.target_os or os.getenv("LUAI_TARGET_OS"),
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    })
    if not profile then return nil end
    if value ~= profile.launcher_profile then
        return invalidOption("launcher_profile", string.format(
            "launcher_profile is derived from the target and must be %s",
            tostring(profile.launcher_profile)
        ))
    end
    return nil
end

local ALLOWED_OPTIONS = {
    action = true,
    depscan = true,
    discovery_mode = true,
    entry = true,
    exclude = true,
    include = true,
    launcher_profile = true,
    lua = true,
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
    if opts.entry:find("\0", 1, true) then
        return nil, invalidOption("entry", "entry must not contain NUL bytes")
    end
    local entry_path_err = validateNotDriveRelative(opts.entry, "entry")
    if entry_path_err then
        return nil, entry_path_err
    end
    local include, include_err = normalizeSequenceOption(opts, "include")
    if not include then
        return nil, include_err
    end
    local exclude, exclude_err = normalizeSequenceOption(opts, "exclude")
    if not exclude then
        return nil, exclude_err
    end
    local run_args, run_args_err = normalizeSequenceOption(opts, "run_args")
    if not run_args then
        return nil, run_args_err
    end
    for _, item_value in ipairs(include) do
        local include_path_err = validateNotDriveRelative(item_value, "include")
        if include_path_err then
            return nil, include_path_err
        end
    end
    local max_deps_err = validateMaxDeps(opts)
    if max_deps_err then
        return nil, max_deps_err
    end
    for _, key in ipairs({ "action", "discovery_mode", "launcher_profile", "lua", "lua_prefix", "mode", "out", "target_os" }) do
        local err = validateOptionalString(opts, key)
        if err then
            return nil, err
        end
    end
    for _, key in ipairs({ "lua", "lua_prefix", "out" }) do
        local err = validateNotDriveRelative(opts[key], key)
        if err then
            return nil, err
        end
    end
    for _, binding in ipairs({
        { "lua", "LUAI_LUA" },
        { "lua_prefix", "LUAI_LUA_PREFIX" },
    }) do
        local key, environment_name = binding[1], binding[2]
        if opts[key] == nil then
            local err = validateNotDriveRelative(os.getenv(environment_name), key)
            if err then
                return nil, err
            end
        end
    end
    if type(opts.out) == "string" and opts.out:find("%c") then
        return nil, invalidOption("out", "out must not contain control bytes")
    end
    local target_os_err = validateTargetOs(opts)
    if target_os_err then
        return nil, target_os_err
    end
    local launcher_profile_err = validateLauncherProfile(opts)
    if launcher_profile_err then
        return nil, launcher_profile_err
    end
    for _, key in ipairs({ "depscan", "verbose" }) do
        local err = validateOptionalBoolean(opts, key)
        if err then
            return nil, err
        end
    end

    local normalized = {}
    for key, value in pairs(opts) do
        normalized[key] = value
    end
    if normalized.target_os == "" then
        normalized.target_os = nil
    end
    normalized.include = include
    normalized.exclude = exclude
    normalized.run_args = run_args
    return normalized
end

local function recordFailure(action, failure)
    if failure and failure.ok == false and failure.error then
        logger.logError("api", action, failure.error.message or "operation failed", {
            error_type = failure.error.type,
            entry = failure.error.script_path,
            option = failure.error.option,
        })
    end
    return failure
end

local function dependencyPlan(opts, initial_source_hashes)
    return discovery.plan(opts, {
        initial_source_hashes = initial_source_hashes,
    })
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
    local entry_content, entry_read_err = fs.readRegularFile(normalized.entry)
    if entry_content == nil then
        return nil, makeError("ScriptNotFoundError", string.format("Lua script not found: %s", normalized.entry), {
            script_path = normalized.entry,
            cause = entry_read_err,
        })
    end
    local syntax_ok, syntax_err = pcall(analyzer.validateSource, entry_content, normalized.entry)
    if not syntax_ok then
        return nil, result.fromThrown(syntax_err)
    end

    local entry_path = path.normalize(path.absolute(normalized.entry))
    local dependencies, dep_err = dependencyPlan(normalized, {
        [entry_path] = hash.sha256(entry_content),
    })
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
        return recordFailure("analyze", err)
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
        return recordFailure("trace", err)
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

--@description: Report host/target compatibility diagnostics without building a bundle
--@param opts: table - Options table with entry and optional target_os, lua_prefix
--@return: table - Structured result with host, target, Lua ABI, notes, and warnings
function M.compatibility(opts)
    local context, err = analyzeContext(opts)
    if not context then
        return recordFailure("compatibility", err)
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
        return recordFailure("bundle", err)
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
        target_os = normalized.target_os or os.getenv("LUAI_TARGET_OS"),
        lua_prefix = normalized.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        source_hashes = context.dependencies.source_hashes,
    })
    if not built_manifest.ok then
        return recordFailure("bundle", built_manifest)
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
        return recordFailure("bundle", onefile.bundleOnefile(bundle_opts))
    end

    return recordFailure("bundle", bundler.bundleOnedir(bundle_opts))
end

return M
