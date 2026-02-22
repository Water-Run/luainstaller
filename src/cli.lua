#!/usr/bin/env lua
--[[
Command-line interface for luainstaller.
Provides commands for dependency analysis, log viewing,
engine listing, and compilation. Also serves as the
installed binary entry point via LuaRocks.

Author:
    WaterRun
File:
    cli.lua
Date:
    2026-02-22
Updated:
    2026-02-22
]]


local analyzer = require("luainstaller.analyzer")
local logger   = require("luainstaller.logger")


--@description: Program version string
--@const: VERSION
local VERSION = "1.0.0"

--@description: Project homepage URL
--@const: PROJECT_URL
local PROJECT_URL = "https://github.com/Water-Run/luainstaller"


--@description: Full help text displayed by the help command
--@const: HELP_MESSAGE
local HELP_MESSAGE = string.format([=[
luainstaller - Package Lua scripts into standalone executables

Usage:
    luainstaller                              Show version info
    luainstaller help                         Show this help message
    luainstaller engines                      List supported engines
    luainstaller logs [options]               View operation logs
    luainstaller analyze <script> [options]   Analyze dependencies
    luainstaller build <script> [options]     Build executable

Commands:

  help
      Display this help message.

  engines
      List all supported packaging engines.

  logs [-limit <n>] [--asc] [-level <level>]
      Display stored operation logs.

      Options:
          -limit <n>      Limit the number of logs to display
          --asc           Display in ascending order (default: descending)
          -level <level>  Filter by level (debug, info, warning, error, success)

  analyze <entry_script> [-max <n>] [--detail]
      Perform dependency analysis on the entry script.

      Options:
          -max <n>        Maximum dependency count (default: 36)
          --detail        Show detailed analysis output

  build <entry_script> [options]
      Compile Lua script into standalone executable.

      Options:
          -engine <name>       Packaging engine (default: platform-specific)
          -require <scripts>   Additional dependency scripts (comma-separated)
          -max <n>             Maximum dependency count (default: 36)
          -output <path>       Output executable path
          --manual             Disable automatic dependency analysis
          --detail             Show detailed compilation output

Engines:
    luastatic      - Compile to true native binary (Linux only)
    srlua          - Default srlua for current platform
    winsrlua515    - Windows Lua 5.1.5 (64-bit)
    winsrlua515-32 - Windows Lua 5.1.5 (32-bit)
    winsrlua548    - Windows Lua 5.4.8
    linsrlua515    - Linux Lua 5.1.5 (64-bit)
    linsrlua515-32 - Linux Lua 5.1.5 (32-bit)
    linsrlua548    - Linux Lua 5.4.8

Examples:
    luainstaller build hello.lua
    luainstaller build main.lua -engine srlua -output ./bin/myapp
    luainstaller build app.lua -require utils.lua,config.lua --manual
    luainstaller analyze main.lua -max 100 --detail
    luainstaller logs -limit 20 --asc

Visit: %s
]=], PROJECT_URL)


--@description: Indicator prefix for successful outcomes
--@const: SYM_OK
local SYM_OK = "[OK]"

--@description: Indicator prefix for failed outcomes
--@const: SYM_FAIL
local SYM_FAIL = "[FAIL]"

--@description: Indicator prefix for warnings
--@const: SYM_WARN
local SYM_WARN = "[WARN]"

--@description: Indicator prefix for debug entries
--@const: SYM_DEBUG
local SYM_DEBUG = "[DEBUG]"

--@description: Indicator prefix for informational entries
--@const: SYM_INFO
local SYM_INFO = "[INFO]"


--@description: Map from log level string to display symbol
--@field debug: string
--@field info: string
--@field warning: string
--@field error: string
--@field success: string
local LEVEL_SYMBOLS = {
    debug   = SYM_DEBUG,
    info    = SYM_INFO,
    warning = SYM_WARN,
    error   = SYM_FAIL,
    success = SYM_OK,
}

--@description: Valid log level names for argument validation
--@field [string]: boolean
local VALID_LEVELS = {
    debug   = true,
    info    = true,
    warning = true,
    error   = true,
    success = true,
}


-- ============================================================
-- ArgumentParser
-- ============================================================

--[[
Simple positional argument parser for the CLI.
Maintains a cursor over the argument list and provides
peek, consume, and typed-value consumption methods.

Class:
    ArgumentParser
Fields:
    args: table - List of argument strings
    pos: number - Current cursor position (1-based)
]]
local ArgumentParser = {}
ArgumentParser.__index = ArgumentParser


--@description: Construct a new ArgumentParser
--@param args: table - List of string arguments
--@return: ArgumentParser - New parser instance
function ArgumentParser.new(args)
    local self = setmetatable({}, ArgumentParser)
    self.args  = args
    self.pos   = 1
    return self
end

--@description: Test whether unconsumed arguments remain
--@param self: ArgumentParser - Parser instance
--@return: boolean - True when more arguments are available
function ArgumentParser:hasNext()
    return self.pos <= #self.args
end

--@description: Look at the next argument without consuming it
--@param self: ArgumentParser - Parser instance
--@return: string|nil - Next argument or nil at end
function ArgumentParser:peek()
    if self:hasNext() then
        return self.args[self.pos]
    end
    return nil
end

--@description: Consume and return the next argument
--@param self: ArgumentParser - Parser instance
--@return: string|nil - Consumed argument or nil at end
function ArgumentParser:consume()
    if self:hasNext() then
        local val = self.args[self.pos]
        self.pos = self.pos + 1
        return val
    end
    return nil
end

--@description: Consume the next argument as a value for the named option, exiting on failure
--@param self: ArgumentParser - Parser instance
--@param option_name: string - Name of the option (for error display)
--@return: string - The consumed value
function ArgumentParser:consumeValue(option_name)
    local val = self:consume()
    if val == nil or val:sub(1, 1) == "-" then
        io.stderr:write(string.format("Error: Option '%s' requires a value\n", option_name))
        os.exit(1)
    end
    return val
end

-- ============================================================
-- Output Helpers
-- ============================================================

--@description: Print the version banner to stdout
--@local: true
local function printVersion()
    io.write(string.format("luainstaller by WaterRun. Version %s.\n", VERSION))
    io.write(string.format("Visit: %s :-)\n", PROJECT_URL))
end


--@description: Print the full help text to stdout
--@local: true
local function printHelp()
    io.write(HELP_MESSAGE)
end


--@description: Write an error message to stderr
--@local: true
--@param message: string - Error text
local function printError(message)
    io.stderr:write(string.format("Error: %s\n", message))
end


--@description: Write a success message to stdout with the OK symbol
--@local: true
--@param message: string - Success text
local function printSuccess(message)
    io.write(string.format("%s %s\n", SYM_OK, message))
end


--@description: Write an indented informational hint to stdout
--@local: true
--@param message: string - Hint text
local function printHint(message)
    io.write(string.format("  %s\n", message))
end


-- ============================================================
-- Command Handlers
-- ============================================================

--@description: Handle the engines command, listing all supported engines
--@local: true
--@return: number - Exit code
local function cmdEngines()
    io.write("Supported engines:\n")
    io.write(string.rep("=", 50) .. "\n")

    local engine_list = {
        { name = "luastatic",      desc = "Compile to true native binary (Linux only)" },
        { name = "srlua",          desc = "Default srlua for current platform" },
        { name = "winsrlua515",    desc = "Windows Lua 5.1.5 (64-bit)" },
        { name = "winsrlua515-32", desc = "Windows Lua 5.1.5 (32-bit)" },
        { name = "winsrlua548",    desc = "Windows Lua 5.4.8" },
        { name = "linsrlua515",    desc = "Linux Lua 5.1.5 (64-bit)" },
        { name = "linsrlua515-32", desc = "Linux Lua 5.1.5 (32-bit)" },
        { name = "linsrlua548",    desc = "Linux Lua 5.4.8" },
    }

    for _, eng in ipairs(engine_list) do
        io.write(string.format("  %-20s %s\n", eng.name, eng.desc))
    end

    io.write(string.rep("=", 50) .. "\n")
    return 0
end


--@description: Handle the logs command with filtering and display options
--@local: true
--@param parser: ArgumentParser - Remaining arguments
--@return: number - Exit code
local function cmdLogs(parser)
    local limit     = nil
    local ascending = false
    local level     = nil

    while parser:hasNext() do
        local arg = parser:consume()
        if arg == "-limit" then
            local val = parser:consumeValue("-limit")
            limit = tonumber(val)
            if not limit or limit <= 0 or limit ~= math.floor(limit) then
                printError("-limit must be a positive integer")
                return 1
            end
        elseif arg == "--asc" then
            ascending = true
        elseif arg == "-level" then
            level = parser:consumeValue("-level")
            if not VALID_LEVELS[level] then
                printError(string.format("Invalid level: %s", level))
                return 1
            end
        else
            printError(string.format("Unknown option for logs: %s", arg))
            return 1
        end
    end

    local logs = logger.getLogs({
        limit      = limit,
        level      = level,
        descending = not ascending,
    })

    if #logs == 0 then
        io.write("No logs found.\n")
        return 0
    end

    io.write(string.format("Showing %d log(s):\n", #logs))
    io.write(string.rep("=", 60) .. "\n")

    for _, entry in ipairs(logs) do
        local ts     = entry.timestamp or "Unknown"
        local lvl    = entry.level or "info"
        local src    = entry.source or "unknown"
        local action = entry.action or "unknown"
        local msg    = entry.message or ""
        local sym    = LEVEL_SYMBOLS[lvl] or SYM_INFO

        io.write(string.format("[%s] %s [%s:%s] %s\n", ts, sym, src, action, msg))

        if entry.details then
            for k, v in pairs(entry.details) do
                io.write(string.format("    %s: %s\n", tostring(k), tostring(v)))
            end
        end

        io.write(string.rep("-", 60) .. "\n")
    end

    return 0
end


--@description: Handle the analyze command for dependency analysis
--@local: true
--@param parser: ArgumentParser - Remaining arguments
--@return: number - Exit code
local function cmdAnalyze(parser)
    local entry_script = parser:consume()
    if not entry_script or entry_script:sub(1, 1) == "-" then
        printError("analyze command requires an entry script")
        printHint("Usage: luainstaller analyze <script> [-max <n>] [--detail]")
        return 1
    end

    local max_deps = DEFAULT_MAX_DEPS
    local detail   = false

    while parser:hasNext() do
        local arg = parser:consume()
        if arg == "-max" then
            local val = parser:consumeValue("-max")
            max_deps = tonumber(val)
            if not max_deps or max_deps <= 0 or max_deps ~= math.floor(max_deps) then
                printError("-max must be a positive integer")
                return 1
            end
        elseif arg == "--detail" then
            detail = true
        else
            printError(string.format("Unknown option for analyze: %s", arg))
            return 1
        end
    end

    local handle = io.open(entry_script, "r")
    if not handle then
        printError(string.format("Script not found: %s", entry_script))
        return 1
    end
    handle:close()

    if not entry_script:match("%.lua$") then
        printError(string.format("Entry script must be a .lua file: %s", entry_script))
        return 1
    end

    local ok, result = pcall(analyzer.analyzeDependencies, entry_script, {
        max_dependencies = max_deps,
    })

    if not ok then
        local err_msg = type(result) == "table" and result.message or tostring(result)
        printError(err_msg)
        logger.logError("cli", "analyze", string.format("Failed: %s", err_msg))
        return 1
    end

    local entry_name = entry_script:match("[^/\\]+$") or entry_script

    if detail then
        io.write(string.format("Analyzing: %s\n", entry_script))
        io.write(string.format("Max dependencies: %d\n", max_deps))
        io.write(string.rep("=", 60) .. "\n")
    end

    io.write(string.format("Dependencies for %s:\n", entry_name))

    if #result.scripts == 0 and #result.libraries == 0 then
        io.write("  (no dependencies)\n")
    end

    if #result.scripts > 0 then
        io.write("  Scripts:\n")
        for i, dep in ipairs(result.scripts) do
            local dep_name = dep:match("[^/\\]+$") or dep
            if detail then
                io.write(string.format("    %d. %s\n", i, dep_name))
                io.write(string.format("       Path: %s\n", dep))
            else
                io.write(string.format("    %d. %s\n", i, dep_name))
            end
        end
    end

    if #result.libraries > 0 then
        io.write("  Libraries:\n")
        for i, lib in ipairs(result.libraries) do
            local lib_name = lib:match("[^/\\]+$") or lib
            if detail then
                io.write(string.format("    %d. %s\n", i, lib_name))
                io.write(string.format("       Path: %s\n", lib))
            else
                io.write(string.format("    %d. %s\n", i, lib_name))
            end
        end
    end

    io.write(string.format(
        "\nTotal: %d script(s), %d library(ies)\n",
        #result.scripts, #result.libraries
    ))

    logger.logSuccess("cli", "analyze", string.format(
        "Analyzed %s: %d scripts, %d libraries",
        entry_name, #result.scripts, #result.libraries
    ))

    return 0
end


--@description: Handle the build command for script compilation
--@local: true
--@param parser: ArgumentParser - Remaining arguments
--@return: number - Exit code
local function cmdBuild(parser)
    local entry_script = parser:consume()
    if not entry_script or entry_script:sub(1, 1) == "-" then
        printError("build command requires an entry script")
        printHint("Usage: luainstaller build <script> [options]")
        return 1
    end

    local requires = {}
    local max_deps = DEFAULT_MAX_DEPS
    local output   = nil
    local engine   = nil
    local manual   = false
    local detail   = false

    while parser:hasNext() do
        local arg = parser:consume()
        if arg == "-engine" then
            engine = parser:consumeValue("-engine")
        elseif arg == "-require" then
            local val = parser:consumeValue("-require")
            for req in val:gmatch("[^,]+") do
                req = req:gsub("^%s+", ""):gsub("%s+$", "")
                if req ~= "" then
                    requires[#requires + 1] = req
                end
            end
        elseif arg == "-max" then
            local val = parser:consumeValue("-max")
            max_deps = tonumber(val)
            if not max_deps or max_deps <= 0 or max_deps ~= math.floor(max_deps) then
                printError("-max must be a positive integer")
                return 1
            end
        elseif arg == "-output" then
            output = parser:consumeValue("-output")
        elseif arg == "--manual" then
            manual = true
        elseif arg == "--detail" then
            detail = true
        else
            printError(string.format("Unknown option for build: %s", arg))
            return 1
        end
    end

    local handle = io.open(entry_script, "r")
    if not handle then
        printError(string.format("Script not found: %s", entry_script))
        return 1
    end
    handle:close()

    if not entry_script:match("%.lua$") then
        printError(string.format("Entry script must be a .lua file: %s", entry_script))
        return 1
    end

    if detail then
        io.write(string.format("Building: %s\n", entry_script))
        io.write(string.format("Engine: %s\n", engine or "(default)"))
        io.write(string.format("Manual mode: %s\n", manual and "enabled" or "disabled"))
        io.write(string.format("Max dependencies: %d\n", max_deps))
        if output then
            io.write(string.format("Output: %s\n", output))
        end
        if #requires > 0 then
            io.write(string.format("Additional requires: %s\n", table.concat(requires, ", ")))
        end
        io.write(string.rep("=", 60) .. "\n")
    end

    local ok_executor, executor = pcall(require, "luainstaller.executor")
    if not ok_executor then
        printError("Executor module not available. Build functionality not yet implemented.")
        logger.logError("cli", "build", "Executor module not available")
        return 1
    end

    local deps_result
    if manual then
        if detail then
            io.write("Skipping automatic dependency analysis (manual mode)\n")
        end
        deps_result = { scripts = {}, libraries = {} }
    else
        if detail then
            io.write("Analyzing dependencies...\n")
        end
        local ok_analyze, res = pcall(analyzer.analyzeDependencies, entry_script, {
            max_dependencies = max_deps,
        })
        if not ok_analyze then
            local err_msg = type(res) == "table" and res.message or tostring(res)
            printError(err_msg)
            logger.logError("cli", "build", string.format("Analysis failed: %s", err_msg))
            return 1
        end
        deps_result = res
        if detail then
            io.write(string.format("Found %d script(s), %d library(ies)\n",
                #res.scripts, #res.libraries))
        end
    end

    for _, req in ipairs(requires) do
        local req_handle = io.open(req, "r")
        if not req_handle then
            printError(string.format("Required script not found: %s", req))
            return 1
        end
        req_handle:close()
        deps_result.scripts[#deps_result.scripts + 1] = req
    end

    local ok_build, build_result = pcall(executor.compileLuaScript, entry_script, {
        dependencies = deps_result.scripts,
        libraries    = deps_result.libraries,
        engine       = engine,
        output       = output,
        verbose      = detail,
    })

    if not ok_build then
        local err_msg = type(build_result) == "table" and build_result.message or tostring(build_result)
        printError(err_msg)
        logger.logError("cli", "build", string.format("Failed: %s", err_msg))
        return 1
    end

    printSuccess(string.format("Build successful: %s", tostring(build_result)))

    local entry_name = entry_script:match("[^/\\]+$") or entry_script
    logger.logSuccess("cli", "build", string.format(
        "Built %s -> %s", entry_name, tostring(build_result)
    ), { engine = engine or "default" })

    return 0
end


-- ============================================================
-- Main Entry Point
-- ============================================================

--[[
Public module interface for the CLI subsystem.

Author:
    WaterRun
Module:
    cli
]]
local M = {}


--@description: Parse arguments and dispatch to the appropriate command handler
--@param args: table - Argument table (typically the global arg)
--@return: number - Process exit code (0 for success, non-zero for failure)
--@usage: os.exit(cli.main(arg))
function M.main(args)
    args = args or {}

    local positional = {}
    for i = 1, #args do
        positional[#positional + 1] = args[i]
    end

    local parser = ArgumentParser.new(positional)

    if not parser:hasNext() then
        printVersion()
        return 0
    end

    local command = parser:consume()

    if command == "help" or command == "-h" or command == "--help" then
        printHelp()
        return 0
    end

    if command == "version" or command == "-v" or command == "--version" then
        printVersion()
        return 0
    end

    if command == "engines" then
        return cmdEngines()
    end

    if command == "logs" then
        return cmdLogs(parser)
    end

    if command == "analyze" then
        return cmdAnalyze(parser)
    end

    if command == "build" then
        return cmdBuild(parser)
    end

    if command:match("%.lua$") then
        local build_args = { command }
        for i = parser.pos, #parser.args do
            build_args[#build_args + 1] = parser.args[i]
        end
        return cmdBuild(ArgumentParser.new(build_args))
    end

    printError(string.format("Unknown command: %s", command))
    printHint("Run 'luainstaller help' for usage information")
    return 1
end

--@description: Detect module vs script context and act accordingly
--@local: true
local _modname = ...
if _modname ~= "luainstaller.cli" then
    os.exit(M.main(arg) or 0)
end

return M
