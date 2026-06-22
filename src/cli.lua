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

local function localFileExists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function installSourcePreloads()
    local script_path = arg and arg[0] or ""
    local source_dir = script_path:match("^(.*[/\\])[^/\\]+$") or "src/"
    local function sourcePath(name)
        return source_dir .. name
    end

    if package.preload["luainstaller"] or not localFileExists(sourcePath("init.lua")) then
        return
    end

    package.preload["luainstaller.analyzer"] = package.preload["luainstaller.analyzer"] or function()
        return dofile(sourcePath("analyzer.lua"))
    end
    package.preload["luainstaller.logger"] = package.preload["luainstaller.logger"] or function()
        return dofile(sourcePath("logger.lua"))
    end
    package.preload["luainstaller.manifest"] = package.preload["luainstaller.manifest"] or function()
        return dofile(sourcePath("manifest.lua"))
    end
    package.preload["luainstaller.compat"] = package.preload["luainstaller.compat"] or function()
        return dofile(sourcePath("compat.lua"))
    end
    package.preload["luainstaller.platform"] = package.preload["luainstaller.platform"] or function()
        return dofile(sourcePath("platform.lua"))
    end
    package.preload["luainstaller.cgen"] = package.preload["luainstaller.cgen"] or function()
        return dofile(sourcePath("cgen.lua"))
    end
    package.preload["luainstaller.launcher"] = package.preload["luainstaller.launcher"] or function()
        return dofile(sourcePath("launcher.lua"))
    end
    package.preload["luainstaller.bundler"] = package.preload["luainstaller.bundler"] or function()
        return dofile(sourcePath("bundler.lua"))
    end
    package.preload["luainstaller.require_engine"] = package.preload["luainstaller.require_engine"] or function()
        return dofile(sourcePath("require_engine.lua"))
    end
    package.preload["luainstaller.onefile"] = package.preload["luainstaller.onefile"] or function()
        return dofile(sourcePath("onefile.lua"))
    end
    package.preload["luainstaller"] = function()
        return dofile(sourcePath("init.lua"))
    end
end

installSourcePreloads()

local luainstaller = require("luainstaller")
local logger       = require("luainstaller.logger")


--@description: Program version string
--@const: VERSION
local VERSION = "1.0.0"

--@description: Project homepage URL
--@const: PROJECT_URL
local PROJECT_URL = "https://github.com/Water-Run/luainstaller"

--@description: Default maximum dependency count
--@const: DEFAULT_MAX_DEPS
local DEFAULT_MAX_DEPS = 36


--@description: Full help text displayed by the help command
--@const: HELP_MESSAGE
local HELP_MESSAGE = string.format([=[
luai / luainstaller - Package Lua projects into same-environment executables

Usage:
    luai --help
    luai --version
    luai a <entry.lua> [options]
    luai t <entry.lua> [options]
    luai b <entry.lua> [options]

Command names:
  luai, luainstaller

Actions:

  a <entry.lua>
      Analyze dependencies.

  t <entry.lua>
      Trace dependency resolution decisions.

  b <entry.lua>
      Build a bundle. --dir is the default output mode; --file builds a
      self-extracting executable.

Options:
  --dir, --onedir       Select directory bundle mode (default)
  --file, --onefile     Select self-extracting single-file bundle mode
  -o, --out <path>      Output path for bundle actions
  --include <path>      Include an extra Lua file; repeatable
  --exclude <path>      Exclude a dependency by path or basename; repeatable
  --target-os <os>      Target profile: linux, macos, or windows
  --lua-prefix <path>   Lua prefix for targets that require one
  -r, --require-engine <e>
                        Dependency engine: static, manual, or runtime
  --no-depscan          Disable automatic dependency scanning
  --max-deps <n>        Maximum dependency count (default: 36)
  --verbose             Print more detail

Compatibility commands:
  -a, analyze <entry.lua>  Compatibility alias for a
  -t, trace <entry.lua>    Compatibility alias for t
  -c, build <entry.lua>    Compatibility alias for b
  logs [options]           View operation logs
  engines                  List legacy engine names kept for compatibility

Compatibility:
  The first runtime promise is same OS, same architecture, same ABI, and same
  Lua ABI. Linux uses a shared-Lua launcher. macOS uses a static Lua prefix.
  Windows currently uses a MinGW-built launcher and a bundled Lua DLL.

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
    io.write(string.format("luainstaller %s  LGPL 3.0 by WaterRun\n", VERSION))
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


--@description: Write an indented informational hint to stdout
--@local: true
--@param message: string - Hint text
local function printHint(message)
    io.write(string.format("  %s\n", message))
end

local function newOptions()
    return {
        include = {},
        exclude = {},
        run_args = {},
        depscan = true,
        mode    = "onedir",
        max_deps = DEFAULT_MAX_DEPS,
        verbose = false,
    }
end

local function parsePositiveInteger(value, option_name)
    local number = tonumber(value)
    if not number or number <= 0 or number ~= math.floor(number) then
        return nil, string.format("%s must be a positive integer", option_name)
    end
    return number
end

local function parseActionOptions(parser, action, first_entry)
    local opts = newOptions()
    opts.action = action
    opts.entry  = first_entry

    while parser:hasNext() do
        local arg = parser:consume()
        if arg == "--dir" or arg == "--onedir" then
            opts.mode = "onedir"
        elseif arg == "--file" or arg == "--onefile" then
            opts.mode = "onefile"
        elseif arg == "-o" or arg == "--out" or arg == "-output" then
            opts.out = parser:consumeValue(arg)
        elseif arg == "--include" then
            opts.include[#opts.include + 1] = parser:consumeValue(arg)
        elseif arg == "--exclude" then
            opts.exclude[#opts.exclude + 1] = parser:consumeValue(arg)
        elseif arg == "--target-os" then
            opts.target_os = parser:consumeValue(arg)
        elseif arg == "--lua-prefix" then
            opts.lua_prefix = parser:consumeValue(arg)
        elseif arg == "-r" or arg == "--require-engine" then
            opts.require_engine = parser:consumeValue(arg)
        elseif arg == "--no-depscan" or arg == "--manual" then
            opts.depscan = false
            opts.require_engine = "manual"
        elseif arg == "--max-deps" or arg == "-max" then
            local number, err = parsePositiveInteger(parser:consumeValue(arg), arg)
            if not number then
                return nil, err
            end
            opts.max_deps = number
        elseif arg == "--verbose" or arg == "--detail" then
            opts.verbose = true
        elseif arg == "--" then
            while parser:hasNext() do
                opts.run_args[#opts.run_args + 1] = parser:consume()
            end
            break
        elseif arg == "-require" then
            local val = parser:consumeValue(arg)
            for req in val:gmatch("[^,]+") do
                req = req:gsub("^%s+", ""):gsub("%s+$", "")
                if req ~= "" then
                    opts.include[#opts.include + 1] = req
                end
            end
        elseif arg == "-engine" then
            opts.require_engine = parser:consumeValue(arg)
        elseif not opts.entry and arg:sub(1, 1) ~= "-" then
            opts.entry = arg
        else
            return nil, string.format("Unknown option for %s: %s", action, arg)
        end
    end

    if not opts.entry then
        return nil, string.format("%s requires an entry script", action)
    end

    return opts
end

local function printStructuredError(result)
    local err = result and result.error or {}
    local err_type = err.type or "LuaInstallerError"
    local message = err.message or "operation failed"
    printError(string.format("%s: %s", err_type, message))
end

local function renderVerboseTrace(result)
    io.write(string.format("trace records: %d\n", #(result.trace or {})))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "  trace %d: %s %s%s%s\n",
            i,
            item.requested or "(unknown)",
            item.reason or "unknown",
            item.selected_path and " -> " or "",
            item.selected_path or ""
        ))
    end
end

local function renderDependencySummary(result, verbose)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    io.write("success.\n")
    io.write(string.format("%s\n", result.entry))
    io.write(string.format("%d script(s), %d library(ies)\n", #deps.scripts, #deps.libraries))
    for i, path in ipairs(deps.scripts) do
        io.write(string.format("  script %d: %s\n", i, path))
    end
    for i, path in ipairs(deps.libraries) do
        io.write(string.format("  library %d: %s\n", i, path))
    end
    if verbose then
        renderVerboseTrace(result)
    end
end

local function renderTrace(result)
    io.write("trace.\n")
    io.write(string.format("%s\n", result.entry))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "  %d) %s %s %s%s%s\n",
            i,
            item.classification or item.selected_type or "unknown",
            item.reason or "unknown",
            item.requested or "(unknown)",
            item.selected_path and " -> " or "",
            item.selected_path or ""
        ))
    end
    if result.compatibility then
        io.write("compatibility.\n")
        io.write(string.format("  %s\n", result.compatibility.summary or "unknown"))
        for _, note in ipairs(result.compatibility.notes or {}) do
            io.write(string.format("  note: %s\n", note))
        end
        for _, warning in ipairs(result.compatibility.warnings or {}) do
            io.write(string.format("  warning: %s\n", warning))
        end
    end
end

local function cmdAction(parser, action, first_entry)
    local opts, err = parseActionOptions(parser, action, first_entry)
    if not opts then
        printError(err)
        return 1
    end

    local result
    if action == "analyze" then
        result = luainstaller.analyze(opts)
        if result.ok then
            renderDependencySummary(result, opts.verbose)
            return 0
        end
    elseif action == "trace" then
        result = luainstaller.trace(opts)
        if result.ok then
            renderTrace(result)
            return 0
        end
    elseif action == "bundle" then
        result = luainstaller.bundle(opts)
        if result.ok then
            io.write("success.\n")
            if result.executable then
                io.write(string.format("%s\n", result.executable))
            end
            if opts.verbose then
                local manifest = result.manifest or {}
                local modules = manifest.modules or {}
                io.write(string.format("mode: %s\n", result.mode or opts.mode or "unknown"))
                io.write(string.format("lua modules: %d\n", #(modules.lua or {})))
                io.write(string.format("native modules: %d\n", #(modules.native or {})))
            end
            return 0
        end
    end

    printStructuredError(result)
    return 1
end


-- ============================================================
-- Command Handlers
-- ============================================================

--@description: Handle the engines command, listing all supported engines
--@local: true
--@return: number - Exit code
local function cmdEngines()
    io.write("Legacy engine names:\n")
    io.write("  current bundler ignores -engine; use --require-engine for dependency discovery\n")
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

    if command == "h" or command == "help" or command == "-h" or command == "--help" then
        printHelp()
        return 0
    end

    if command == "v" or command == "version" or command == "-v" or command == "--version" then
        printVersion()
        return 0
    end

    if command == "eng" or command == "engines" then
        return cmdEngines()
    end

    if command == "log" or command == "logs" then
        return cmdLogs(parser)
    end

    if command == "a" or command == "-a" then
        return cmdAction(parser, "analyze")
    end

    if command == "t" or command == "-t" or command == "trace" then
        return cmdAction(parser, "trace")
    end

    if command == "b" or command == "-b" or command == "-c" then
        return cmdAction(parser, "bundle")
    end

    if command == "analyze" then
        return cmdAction(parser, "analyze")
    end

    if command == "bundle" or command == "build" or command == "pack" then
        return cmdAction(parser, "bundle")
    end

    if command:match("%.lua$") then
        local build_args = { command }
        for i = parser.pos, #parser.args do
            build_args[#build_args + 1] = parser.args[i]
        end
        return cmdAction(ArgumentParser.new(build_args), "bundle")
    end

    printError(string.format("Unknown command: %s", command))
    printHint("Run 'luai --help' for usage information")
    return 1
end

--@description: Detect module vs script context and act accordingly
--@local: true
local _modname = ...
if _modname ~= "luainstaller.cli" then
    os.exit(M.main(arg) or 0)
end

return M
