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


--@description: Perform dependency analysis on a Lua entry script
--@param entry: string - Path to the entry Lua script
--@param max_deps: number|nil - Maximum dependency count (default 36)
--@return: table - Result with scripts (list of paths) and libraries (list of paths)
--@raise: ScriptNotFoundError, CircularDependencyError, DynamicRequireError, DependencyLimitExceededError, ModuleNotFoundError
--@usage: local result = luainstaller.analyze("main.lua", 100)
function M.analyze(entry, max_deps)
    return analyzer.analyzeDependencies(entry, {
        max_dependencies = max_deps,
    })
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

--@description: Bundle multiple Lua scripts into a single output file
--@param scripts: table - Ordered list of script paths (last is the entry)
--@param output: string - Output file path
--@raise: error when the wrapper module is not available or scripts is empty
--@usage: luainstaller.bundleToSinglefile({"a.lua", "b.lua"}, "out.lua")
function M.bundleToSinglefile(scripts, output)
    assert(type(scripts) == "table" and #scripts > 0, "scripts list cannot be empty")

    local ok_wrapper, wrapper = pcall(require, "luainstaller.wrapper")
    if not ok_wrapper then
        error({
            type    = "NotImplementedError",
            message = "Source bundling is not yet implemented",
        })
    end

    local entry_script = scripts[#scripts]
    local dependencies = {}
    for i = 1, #scripts - 1 do
        dependencies[#dependencies + 1] = scripts[i]
    end

    wrapper.bundleSources(entry_script, dependencies, output)
end

--@description: Analyze dependencies and compile a Lua script into a standalone executable
--@param entry: string - Path to the entry Lua script
--@param opts: table|nil - Build options: engine (string|nil), requires (table|nil), max_deps (number|nil), output (string|nil), manual (boolean|nil)
--@return: string - Absolute path of the generated executable
--@raise: ScriptNotFoundError, EngineNotFoundError, CompilationFailedError, OutputFileNotFoundError
--@usage: luainstaller.build("app.lua", {engine = "srlua", output = "./myapp"})
function M.build(entry, opts)
    opts           = opts or {}
    local max_deps = opts.max_deps or 36
    local manual   = opts.manual or false

    local deps_result
    if manual then
        deps_result = { scripts = {}, libraries = {} }
    else
        deps_result = analyzer.analyzeDependencies(entry, {
            max_dependencies = max_deps,
        })
    end

    if opts.requires then
        for _, req in ipairs(opts.requires) do
            local handle = io.open(req, "r")
            if not handle then
                error({
                    type    = "ScriptNotFoundError",
                    message = string.format("Required script not found: %s", req),
                })
            end
            handle:close()
            deps_result.scripts[#deps_result.scripts + 1] = req
        end
    end

    local ok_executor, executor = pcall(require, "luainstaller.executor")
    if not ok_executor then
        error({
            type    = "NotImplementedError",
            message = "Compilation executor is not yet implemented",
        })
    end

    local result = executor.compileLuaScript(entry, {
        dependencies = deps_result.scripts,
        libraries    = deps_result.libraries,
        engine       = opts.engine,
        output       = opts.output,
        verbose      = false,
    })

    local entry_name = entry:match("[^/\\]+$") or entry
    local result_name = tostring(result):match("[^/\\]+$") or tostring(result)
    logger.logSuccess("api", "build", string.format(
        "Built %s -> %s", entry_name, result_name
    ), { engine = opts.engine or "default" })

    return result
end

return M
