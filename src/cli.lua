#!/usr/bin/env lua
--[[
Command-line interface for luainstaller.
Provides split command personalities for luai and luainstaller.

Author:
    WaterRun
File:
    cli.lua
Date:
    2026-02-22
Updated:
    2026-06-24
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
    local source_dir = script_path:match("^(.*[/\\])[^/\\]+$")
    if not source_dir and script_path ~= "" and not script_path:find("[/\\]", 1) then
        -- Bare command name: resolve via PATH when possible (POSIX).
        local pipe = io.popen("command -v " .. script_path:gsub("'", "'\\''") .. " 2>/dev/null", "r")
        if pipe then
            local resolved = pipe:read("*l") or ""
            pipe:close()
            source_dir = resolved:match("^(.*[/\\])[^/\\]+$")
        end
    end
    -- Do not guess CWD/src/. Missing source_dir means use installed package path.
    local function sourcePath(name)
        if not source_dir then
            return nil
        end
        return source_dir .. name
    end

    if package.preload["luainstaller"] or not source_dir or not localFileExists(sourcePath("init.lua")) then
        return
    end

    -- Clear cached installed modules so checkout source wins over LuaRocks.
    local module_names = {
        "luainstaller",
        "luainstaller.process",
        "luainstaller.path",
        "luainstaller.result",
        "luainstaller.analyzer",
        "luainstaller.logger",
        "luainstaller.manifest",
        "luainstaller.compat",
        "luainstaller.platform",
        "luainstaller.cgen",
        "luainstaller.launcher",
        "luainstaller.bundler",
        "luainstaller.discovery",
        "luainstaller.onefile",
        "luainstaller.runtime",
    }
    for _, name in ipairs(module_names) do
        package.loaded[name] = nil
    end

    package.preload["luainstaller.process"] = package.preload["luainstaller.process"] or function()
        return dofile(sourcePath("process.lua"))
    end
    package.preload["luainstaller.path"] = package.preload["luainstaller.path"] or function()
        return dofile(sourcePath("path.lua"))
    end
    package.preload["luainstaller.result"] = package.preload["luainstaller.result"] or function()
        return dofile(sourcePath("result.lua"))
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
    package.preload["luainstaller.discovery"] = package.preload["luainstaller.discovery"] or function()
        return dofile(sourcePath("discovery.lua"))
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
local logger = require("luainstaller.logger")

local VERSION = "1.0.0"
local PROJECT_URL = "https://github.com/Water-Run/luainstaller"
local DEFAULT_MAX_DEPS = 36

local LUAI_HELP = [=[
Usage: luai -h
       luai -v
       luai -a <entry.lua> [options]
       luai -t <entry.lua> [options]
       luai -b <entry.lua> [options]

Commands:
  -a <entry.lua>    analyze dependencies
  -t <entry.lua>    trace dependency resolution
  -b <entry.lua>    build a bundle

Options:
  --dir, --onedir       directory bundle mode
  --file, --onefile     self-extracting single-file mode
  -o, --out <path>      output path
  --include <path>      include an extra file
  --exclude <path>      exclude a dependency
  --target-os <os>      linux, macos, or windows
  --lua <path>          Lua interpreter for runtime discovery
  --lua-prefix <path>   Lua prefix for profiled targets
  -d, --discovery-mode <mode>
                        static, manual, or runtime
  --no-depscan          manual dependencies only
  --max-deps <n>        dependency count limit
  --verbose             more detail
]=]

local LUAINSTALLER_HELP = string.format([=[
luainstaller - Package Lua projects into same-environment executables

Usage: luainstaller <command> [arguments] [options]

Commands:
  help                         Show this help.
  version                      Show version and license.
  luainstaller analyze <entry.lua>
                               Analyze Lua and native module dependencies.
  luainstaller trace <entry.lua>
                               Show dependency resolution decisions.
  luainstaller build <entry.lua>
                               Build a directory or onefile bundle.
  luainstaller logs [options]  View operation logs.

Build options:
  --dir, --onedir              Directory bundle mode (default).
  --file, --onefile            Self-extracting single-file mode.
  -o, --out <path>             Output path.
  --include <path>             Include an extra file; repeatable.
  --exclude <path>             Exclude a dependency; repeatable.
  --target-os <os>             Target profile: linux, macos, or windows.
  --lua <path>                 Lua interpreter for runtime discovery.
  --lua-prefix <path>          Lua prefix for profiled targets.
  -d, --discovery-mode <mode>
                               Dependency discovery mode: static, manual, runtime.
  --no-depscan                 Manual dependencies only.
  --max-deps <n>               Dependency count limit (default: 36).
  --verbose                    Show additional details.

Examples:
  luainstaller analyze test/student_management_system/main.lua --max-deps 250
  luainstaller trace test/student_management_system/main.lua --max-deps 250
  luainstaller build --dir test/student_management_system/main.lua -o build/student-manager

Visit: %s
]=], PROJECT_URL)

local VALID_LEVELS = {
    debug = true,
    info = true,
    warning = true,
    error = true,
    success = true,
}

local ArgumentParser = {}
ArgumentParser.__index = ArgumentParser

function ArgumentParser.new(args)
    return setmetatable({
        args = args or {},
        pos = 1,
    }, ArgumentParser)
end

function ArgumentParser:hasNext()
    return self.pos <= #self.args
end

function ArgumentParser:consume()
    if not self:hasNext() then
        return nil
    end
    local value = self.args[self.pos]
    self.pos = self.pos + 1
    return value
end

function ArgumentParser:consumeValue(option_name)
    local value = self:consume()
    if value == nil then
        return nil, string.format("%s requires a value", option_name)
    end
    return value
end

local function basename(path)
    path = tostring(path or ""):gsub("\\", "/")
    return path:match("[^/]+$") or path
end

local function stripExtension(name)
    return tostring(name or ""):gsub("%.lua$", ""):gsub("%.cmd$", ""):gsub("%.exe$", "")
end

local function detectProgram(context)
    context = context or {}
    local name = context.program_name or os.getenv("LUAINSTALLER_CLI_NAME")
    if not name or name == "" then
        name = basename(arg and arg[0] or "")
    end
    name = stripExtension(basename(name))
    if name == "luainstaller" then
        return "luainstaller"
    end
    return "luai"
end

local function supportsColor(context)
    context = context or {}
    if context.color ~= nil then
        return context.color and true or false
    end
    if os.getenv("NO_COLOR") or os.getenv("CI") then
        return false
    end
    return context.interactive and true or false
end

local Ui = {}
Ui.__index = Ui

function Ui.new(context)
    context = context or {}
    return setmetatable({
        color = supportsColor(context),
        animations = context.animations and true or false,
    }, Ui)
end

function Ui:paint(code, text)
    if not self.color then
        return text
    end
    return string.format("\27[%sm%s\27[0m", code, text)
end

function Ui:heading(text)
    return self:paint("1;36", text)
end

function Ui:ok(text)
    return self:paint("1;32", text)
end

function Ui:warn(text)
    return self:paint("1;33", text)
end

function Ui:err(text)
    return self:paint("1;31", text)
end

function Ui:progress(label)
    if self.animations then
        io.write(string.format("%s %s\r", self:paint("36", "|"), label))
    end
end

function Ui:clearProgress()
    if self.animations then
        io.write("                    \r")
    end
end

local function writeClassicError(message)
    io.stderr:write(string.format("error: %s\n", message))
end

local function writeClassicHint(message)
    io.stderr:write(string.format("try: %s\n", message))
end

local function writeModernError(ui, message)
    io.stderr:write(string.format("%s %s\n", ui:err("error:"), message))
end

local function writeModernHint(message)
    io.stderr:write(string.format("hint: %s\n", message))
end

local function newOptions()
    return {
        include = {},
        exclude = {},
        run_args = {},
        depscan = true,
        mode = "onedir",
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
    opts.entry = first_entry

    while parser:hasNext() do
        local item = parser:consume()
        if item == "--dir" or item == "--onedir" then
            opts.mode = "onedir"
        elseif item == "--file" or item == "--onefile" then
            opts.mode = "onefile"
        elseif item == "-o" or item == "--out" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.out = value
        elseif item == "--include" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.include[#opts.include + 1] = value
        elseif item == "--exclude" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.exclude[#opts.exclude + 1] = value
        elseif item == "--target-os" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.target_os = value
        elseif item == "--lua" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.lua = value
        elseif item == "--lua-prefix" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.lua_prefix = value
        elseif item == "-d" or item == "--discovery-mode" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.discovery_mode = value
        elseif item == "--no-depscan" then
            opts.depscan = false
            opts.discovery_mode = "manual"
        elseif item == "--max-deps" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            local number, err = parsePositiveInteger(value, item)
            if not number then
                return nil, err
            end
            opts.max_deps = number
        elseif item == "--verbose" then
            opts.verbose = true
        elseif item == "--" then
            while parser:hasNext() do
                opts.run_args[#opts.run_args + 1] = parser:consume()
            end
            break
        elseif not opts.entry and item:sub(1, 1) ~= "-" then
            opts.entry = item
        else
            return nil, string.format("unknown option for %s: %s", action, item)
        end
    end

    if not opts.entry then
        return nil, string.format("%s requires an entry script", action)
    end

    return opts
end

local function structuredErrorText(result)
    local err = result and result.error or {}
    local err_type = err.type or "LuaInstallerError"
    local message = err.message or "operation failed"
    return string.format("%s: %s", err_type, message)
end

local function renderClassicVerboseTrace(result)
    io.write(string.format("trace-records: %d\n", #(result.trace or {})))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "trace[%d]: %s %s%s%s\n",
            i,
            item.requested or "(unknown)",
            item.reason or "unknown",
            item.selected_path and " -> " or "",
            item.selected_path or ""
        ))
    end
end

local function renderClassicAnalyze(result, verbose)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    io.write("ok\n")
    io.write(string.format("entry: %s\n", result.entry))
    io.write(string.format("scripts: %d\n", #deps.scripts))
    io.write(string.format("libraries: %d\n", #deps.libraries))
    for i, path in ipairs(deps.scripts) do
        io.write(string.format("script[%d]: %s\n", i, path))
    end
    for i, path in ipairs(deps.libraries) do
        io.write(string.format("library[%d]: %s\n", i, path))
    end
    if verbose then
        renderClassicVerboseTrace(result)
    end
end

local function renderClassicTrace(result)
    io.write("trace\n")
    io.write(string.format("entry: %s\n", result.entry))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "%d: %s %s %s%s%s\n",
            i,
            item.classification or item.selected_type or "unknown",
            item.reason or "unknown",
            item.requested or "(unknown)",
            item.selected_path and " -> " or "",
            item.selected_path or ""
        ))
    end
    if result.compatibility then
        io.write(string.format("compatibility: %s\n", result.compatibility.summary or "unknown"))
        for _, note in ipairs(result.compatibility.notes or {}) do
            io.write(string.format("note: %s\n", note))
        end
        for _, warning in ipairs(result.compatibility.warnings or {}) do
            io.write(string.format("warning: %s\n", warning))
        end
    end
end

local function renderClassicBundle(result, opts)
    io.write("ok\n")
    if result.executable then
        io.write(string.format("executable: %s\n", result.executable))
    end
    if opts.verbose then
        local manifest = result.manifest or {}
        local modules = manifest.modules or {}
        io.write(string.format("mode: %s\n", result.mode or opts.mode or "unknown"))
        io.write(string.format("lua-modules: %d\n", #(modules.lua or {})))
        io.write(string.format("native-modules: %d\n", #(modules.native or {})))
    end
end

local function renderModernAnalyze(ui, result, verbose)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    io.write(ui:heading("Analysis complete") .. "\n")
    io.write(string.format("  Entry: %s\n", result.entry))
    io.write(string.format("  Lua scripts: %s\n", ui:ok(tostring(#deps.scripts))))
    io.write(string.format("  Native libraries: %s\n", ui:ok(tostring(#deps.libraries))))
    if verbose then
        io.write("\nResolution trace\n")
        for i, item in ipairs(result.trace or {}) do
            io.write(string.format(
                "  %d. %s %s%s%s\n",
                i,
                item.requested or "(unknown)",
                item.reason or "unknown",
                item.selected_path and " -> " or "",
                item.selected_path or ""
            ))
        end
    end
end

local function renderModernTrace(ui, result)
    io.write(ui:heading("Dependency trace") .. "\n")
    io.write(string.format("  Entry: %s\n", result.entry))
    for i, item in ipairs(result.trace or {}) do
        io.write(string.format(
            "  %d. %s  %s  %s%s%s\n",
            i,
            item.classification or item.selected_type or "unknown",
            item.reason or "unknown",
            item.requested or "(unknown)",
            item.selected_path and " -> " or "",
            item.selected_path or ""
        ))
    end
    if result.compatibility then
        io.write("\n" .. ui:heading("Compatibility") .. "\n")
        io.write(string.format("  %s\n", result.compatibility.summary or "unknown"))
        for _, note in ipairs(result.compatibility.notes or {}) do
            io.write(string.format("  note: %s\n", note))
        end
        for _, warning in ipairs(result.compatibility.warnings or {}) do
            io.write(string.format("  %s %s\n", ui:warn("warning:"), warning))
        end
    end
end

local function renderModernBundle(ui, result, opts)
    io.write(ui:heading("Build complete") .. "\n")
    if result.executable then
        io.write(string.format("  Executable: %s\n", ui:ok(result.executable)))
    end
    if opts.verbose then
        local manifest = result.manifest or {}
        local modules = manifest.modules or {}
        io.write(string.format("  Mode: %s\n", result.mode or opts.mode or "unknown"))
        io.write(string.format("  Lua modules: %d\n", #(modules.lua or {})))
        io.write(string.format("  Native modules: %d\n", #(modules.native or {})))
    end
end

local function runAction(style, ui, parser, action, first_entry)
    local opts, err = parseActionOptions(parser, action, first_entry)
    if not opts then
        if style == "modern" then
            writeModernError(ui, err)
            writeModernHint("run `luainstaller help`")
        else
            writeClassicError(err)
            writeClassicHint("luai -h")
        end
        return 1
    end

    local result
    if action == "analyze" then
        ui:progress("Analyzing")
        result = luainstaller.analyze(opts)
        ui:clearProgress()
        if result.ok then
            if style == "modern" then
                renderModernAnalyze(ui, result, opts.verbose)
            else
                renderClassicAnalyze(result, opts.verbose)
            end
            return 0
        end
    elseif action == "trace" then
        ui:progress("Tracing")
        result = luainstaller.trace(opts)
        ui:clearProgress()
        if result.ok then
            if style == "modern" then
                renderModernTrace(ui, result)
            else
                renderClassicTrace(result)
            end
            return 0
        end
    elseif action == "bundle" then
        ui:progress("Building")
        result = luainstaller.bundle(opts)
        ui:clearProgress()
        if result.ok then
            if style == "modern" then
                renderModernBundle(ui, result, opts)
            else
                renderClassicBundle(result, opts)
            end
            return 0
        end
    end

    if style == "modern" then
        writeModernError(ui, structuredErrorText(result))
    else
        writeClassicError(structuredErrorText(result))
    end
    return 1
end

local function parseLogOptions(parser, style, ui)
    local limit = nil
    local ascending = false
    local level = nil

    while parser:hasNext() do
        local item = parser:consume()
        if item == "--limit" or item == "-limit" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            limit = tonumber(value)
            if not limit or limit <= 0 or limit ~= math.floor(limit) then
                return nil, "--limit must be a positive integer"
            end
        elseif item == "--asc" then
            ascending = true
        elseif item == "--level" or item == "-level" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            if not VALID_LEVELS[value] then
                return nil, string.format("invalid log level: %s", value)
            end
            level = value
        else
            return nil, string.format("unknown option for logs: %s", item)
        end
    end

    return {
        limit = limit,
        level = level,
        descending = not ascending,
    }
end

local function runLogs(parser, style, ui)
    local opts, err = parseLogOptions(parser, style, ui)
    if not opts then
        if style == "modern" then
            writeModernError(ui, err)
        else
            writeClassicError(err)
        end
        return 1
    end

    local logs = logger.getLogs(opts)
    if #logs == 0 then
        io.write(style == "modern" and "No logs found.\n" or "no logs\n")
        return 0
    end

    if style == "modern" then
        io.write(ui:heading(string.format("Showing %d log(s)", #logs)) .. "\n")
    else
        io.write(string.format("logs: %d\n", #logs))
    end

    for _, entry in ipairs(logs) do
        local ts = entry.timestamp or "unknown"
        local lvl = entry.level or "info"
        local src = entry.source or "unknown"
        local action = entry.action or "unknown"
        local msg = entry.message or ""
        if style == "modern" then
            io.write(string.format("  [%s] %-7s %s:%s %s\n", ts, lvl, src, action, msg))
        else
            io.write(string.format("%s\t%s\t%s:%s\t%s\n", ts, lvl, src, action, msg))
        end
    end
    return 0
end

local function runLuai(args, context)
    local parser = ArgumentParser.new(args)
    local ui = Ui.new({ color = false, animations = false })

    if not parser:hasNext() then
        io.write(string.format("luai %s\n", VERSION))
        return 0
    end

    local command = parser:consume()
    if command == "-h" then
        io.write(LUAI_HELP)
        return 0
    elseif command == "-v" then
        io.write(string.format("luai %s\n", VERSION))
        return 0
    elseif command == "-a" then
        return runAction("classic", ui, parser, "analyze")
    elseif command == "-t" then
        return runAction("classic", ui, parser, "trace")
    elseif command == "-b" then
        return runAction("classic", ui, parser, "bundle")
    end

    writeClassicError(string.format("unknown luai command: %s", command))
    writeClassicHint("luai -h")
    return 1
end

local function runLuainstaller(args, context)
    local parser = ArgumentParser.new(args)
    local ui = Ui.new(context)

    if not parser:hasNext() then
        io.write(LUAINSTALLER_HELP)
        return 0
    end

    local command = parser:consume()
    if command == "help" then
        io.write(LUAINSTALLER_HELP)
        return 0
    elseif command == "version" then
        io.write(string.format("luainstaller %s  LGPL 3.0 by WaterRun\n", VERSION))
        return 0
    elseif command == "analyze" then
        return runAction("modern", ui, parser, "analyze")
    elseif command == "trace" then
        return runAction("modern", ui, parser, "trace")
    elseif command == "build" then
        return runAction("modern", ui, parser, "bundle")
    elseif command == "logs" then
        return runLogs(parser, "modern", ui)
    end

    writeModernError(ui, string.format("unknown luainstaller command: %s", command))
    writeModernHint("run `luainstaller help`")
    return 1
end

local M = {}

function M.main(args, context)
    args = args or {}
    context = context or {}

    local positional = {}
    for i = 1, #args do
        positional[#positional + 1] = args[i]
    end

    local program = detectProgram(context)
    if program == "luainstaller" then
        return runLuainstaller(positional, context)
    end
    return runLuai(positional, context)
end

local _modname = ...
if _modname ~= "luainstaller.cli" then
    os.exit(M.main(arg) or 0)
end

return M
