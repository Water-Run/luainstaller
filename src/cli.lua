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
    2026-10-19
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
        local quoted_script = "'" .. script_path:gsub("'", "'\\''") .. "'"
        local pipe = io.popen("command -v " .. quoted_script .. " 2>/dev/null", "r")
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
        "luainstaller.fs",
        "luainstaller.windows_fs",
        "luainstaller.windows_host",
        "luainstaller.windows_host_source",
        "luainstaller.hash",
        "luainstaller.process",
        "luainstaller.posix_host",
        "luainstaller.posix_host_source",
        "luainstaller.path",
        "luainstaller.result",
        "luainstaller.lock_owner",
        "luainstaller.distribution_files",
        "luainstaller.lua_abi",
        "luainstaller.native_profile",
        "luainstaller.analyzer",
        "luainstaller.logger",
        "luainstaller.manifest",
        "luainstaller.moon",
        "luainstaller.compat",
        "luainstaller.platform",
        "luainstaller.toolchain",
        "luainstaller.cgen",
        "luainstaller.launcher",
        "luainstaller.bundler",
        "luainstaller.discovery",
        "luainstaller.onefile",
        "luainstaller.runtime",
        "luainstaller.cli_present",
    }
    for _, name in ipairs(module_names) do
        package.loaded[name] = nil
    end

    package.preload["luainstaller.process"] = package.preload["luainstaller.process"] or function()
        return dofile(sourcePath("process.lua"))
    end
    package.preload["luainstaller.fs"] = package.preload["luainstaller.fs"] or function()
        return dofile(sourcePath("fs.lua"))
    end
    for _, leaf in ipairs({ "windows_fs", "windows_host", "windows_host_source",
        "posix_host", "posix_host_source" }) do
        local module_name, filename = "luainstaller." .. leaf, leaf .. ".lua"
        package.preload[module_name] = package.preload[module_name] or function()
            return dofile(sourcePath(filename))
        end
    end
    package.preload["luainstaller.hash"] = package.preload["luainstaller.hash"] or function()
        return dofile(sourcePath("hash.lua"))
    end
    package.preload["luainstaller.path"] = package.preload["luainstaller.path"] or function()
        return dofile(sourcePath("path.lua"))
    end
    package.preload["luainstaller.result"] = package.preload["luainstaller.result"] or function()
        return dofile(sourcePath("result.lua"))
    end
    package.preload["luainstaller.lock_owner"] = package.preload["luainstaller.lock_owner"] or function()
        return dofile(sourcePath("lock_owner.lua"))
    end
    package.preload["luainstaller.distribution_files"] = package.preload["luainstaller.distribution_files"] or function()
        return dofile(sourcePath("distribution_files.lua"))
    end
    package.preload["luainstaller.lua_abi"] = package.preload["luainstaller.lua_abi"] or function()
        return dofile(sourcePath("lua_abi.lua"))
    end
    package.preload["luainstaller.native_profile"] = package.preload["luainstaller.native_profile"] or function()
        return dofile(sourcePath("native_profile.lua"))
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
    package.preload["luainstaller.moon"] = package.preload["luainstaller.moon"] or function()
        return dofile(sourcePath("moon.lua"))
    end
    package.preload["luainstaller.compat"] = package.preload["luainstaller.compat"] or function()
        return dofile(sourcePath("compat.lua"))
    end
    package.preload["luainstaller.platform"] = package.preload["luainstaller.platform"] or function()
        return dofile(sourcePath("platform.lua"))
    end
    package.preload["luainstaller.toolchain"] = package.preload["luainstaller.toolchain"] or function()
        return dofile(sourcePath("toolchain.lua"))
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
    package.preload["luainstaller.cli_present"] = package.preload["luainstaller.cli_present"] or function()
        return dofile(sourcePath("cli_present.lua"))
    end
    package.preload["luainstaller"] = function()
        return dofile(sourcePath("init.lua"))
    end
end

installSourcePreloads()

local luainstaller = require("luainstaller")
local logger = require("luainstaller.logger")
local present = require("luainstaller.cli_present")

local VERSION = "1.8.2"
local PROJECT_URL = "https://github.com/Water-Run/luainstaller"
local DEFAULT_MAX_DEPS = 36

local LUAI_HELP = [=[
Usage: luai -h
       luai -v
       luai -l [log options]
       luai -a <entry.lua> [options]
       luai -t <entry.lua> [options]
       luai -b <entry.lua> [options]

Commands:
  -a <entry.lua>    analyze dependencies
  -t <entry.lua>    trace dependency resolution
  -b <entry.lua>    build a bundle
  -l               read operation logs

Options:
  --dir, --onedir       directory bundle mode
  --file, --onefile     single-file mode (auto)
  --file-mode <mode>   auto, extract, or no-extract
  -M                   skip MoonScript detection
  -o, --out <path>      output path
  --include <path>      include an extra file
  --ffi-library <name=path>  bundle a LuaJIT FFI library; repeatable
  --exclude <path>      exclude a dependency
  --target-os <os>      assert the detected native host OS
  --lua <path>          Lua interpreter for runtime discovery
  --lua-prefix <path>   matching native Lua headers/runtime prefix
  -d, --discovery-mode <mode>
                        static, manual, or runtime
  --no-depscan          manual dependencies only
  --max-deps <n>        dependency count limit
  --runtime-timeout <s> runtime discovery time limit
  --max-source-bytes <n> Lua source size limit
  --max-bundle-bytes <n> combined bundle size limit
  --max-trace-bytes <n> runtime trace size limit
  --verbose             more detail

Log options:
  --level <level>       debug, info, warning, error, or success
  --limit <n>           maximum records
  --asc                 oldest first
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
  --file, --onefile            Single-file mode (auto).
  --file-mode <mode>          auto, extract, or no-extract.
  --no-moon-detect             Skip MoonScript detection.
  -o, --out <path>             Output path.
  --include <path>             Include an extra file; repeatable.
  --ffi-library <name=path>    Bundle a LuaJIT FFI library; repeatable.
  --exclude <path>             Exclude a dependency; repeatable.
  --target-os <os>             Assert the detected native host OS.
  --lua <path>                 Lua interpreter for runtime discovery.
  --lua-prefix <path>          Matching native Lua headers/runtime prefix.
  -d, --discovery-mode <mode>
                               Dependency discovery mode: static, manual, runtime.
  --no-depscan                 Manual dependencies only.
  --max-deps <n>               Dependency count limit (default: 36).
  --runtime-timeout <seconds>  Runtime discovery time limit.
  --max-source-bytes <n>       Lua source size limit.
  --max-bundle-bytes <n>       Combined bundle size limit.
  --max-trace-bytes <n>        Runtime trace size limit.
  --verbose                    Show additional details.
  --color <mode>               auto, always, or never. --no-color is never.
  --progress <mode>            auto, plain, or off. --no-progress is off.
  --format <text|json>         JSON writes one object to stdout and disables color.
  -h, --help                   Show help. `help <command>` covers one command.
  --version                    Show version, runtime, and host. No compiler probe.

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

local MODERN_COMMANDS = {
    help = true, version = true, analyze = true, trace = true, build = true, logs = true,
}

local KNOWN_VALUE_OPTIONS = {
    ["--file-mode"] = true, ["--out"] = true, ["--include"] = true,
    ["--exclude"] = true, ["--ffi-library"] = true, ["--target-os"] = true,
    ["--lua"] = true, ["--lua-prefix"] = true, ["--discovery-mode"] = true,
    ["--max-deps"] = true, ["--runtime-timeout"] = true,
    ["--max-source-bytes"] = true, ["--max-bundle-bytes"] = true,
    ["--max-trace-bytes"] = true, ["--level"] = true, ["--limit"] = true,
    ["--color"] = true, ["--progress"] = true, ["--format"] = true,
    ["-o"] = true, ["-d"] = true,
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
    return self.pending ~= nil or self.pos <= #self.args
end

function ArgumentParser:consume(literal)
    if self.pending ~= nil then
        local value = self.pending
        self.pending = nil
        return value
    end
    if not self:hasNext() then
        return nil
    end
    local value = self.args[self.pos]
    self.pos = self.pos + 1
    local name, inline = tostring(value):match("^(--[%w%-]+)=(.*)$")
    if not literal and name and KNOWN_VALUE_OPTIONS[name] then
        self.pending = inline
        return name
    end
    return value
end

local KNOWN_OPTION_TOKENS = {
    ["-a"] = true, ["-t"] = true, ["-b"] = true, ["-h"] = true, ["-v"] = true,
    ["-o"] = true, ["-d"] = true, ["-M"] = true,
    ["--dir"] = true, ["--onedir"] = true, ["--file"] = true, ["--onefile"] = true,
    ["--file-mode"] = true, ["--no-moon-detect"] = true,
    ["--out"] = true, ["--include"] = true, ["--exclude"] = true,
    ["--ffi-library"] = true,
    ["--target-os"] = true, ["--lua"] = true, ["--lua-prefix"] = true,
    ["--discovery-mode"] = true, ["--no-depscan"] = true, ["--max-deps"] = true,
    ["--verbose"] = true, ["--"] = true,
    ["--runtime-timeout"] = true, ["--max-source-bytes"] = true,
    ["--max-bundle-bytes"] = true, ["--max-trace-bytes"] = true,
    ["--level"] = true, ["--limit"] = true, ["--asc"] = true,
    ["--color"] = true, ["--no-color"] = true, ["--progress"] = true,
    ["--no-progress"] = true, ["--format"] = true, ["--help"] = true,
    ["--version"] = true,
}

function ArgumentParser:consumeValue(option_name)
    local explicit = self.pending ~= nil
    local value = self:consume(true)
    if value == nil then
        return nil, string.format("%s requires a value", option_name)
    end
    -- A value that is itself a recognized option token is almost always a
    -- misplaced option (luai -b entry -o --dir). Dash-prefixed paths remain
    -- valid values as long as they do not collide with a known option.
    local token = type(value) == "string" and (value:match("^(--[%w%-]+)=") or value)
    if not explicit and token and KNOWN_OPTION_TOKENS[token] then
        return nil, string.format(
            "%s requires a value; got the option-like token %s",
            option_name,
            value
        )
    end
    return value
end

local function basename(path)
    path = tostring(path or ""):gsub("\\", "/")
    return path:match("[^/]+$") or path
end

local function stripExtension(name)
    return (tostring(name or ""):gsub("%.lua$", ""):gsub("%.cmd$", ""):gsub("%.exe$", ""))
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
        context = context,
        color = supportsColor(context),
        error_color = context.error_color,
        animations = context.animations and true or false,
        format = context.format or "text",
        progress_mode = context.progress_mode or "off",
        color_level = present.colorLevel(os.getenv, supportsColor(context)),
        rule = package.config:sub(1, 1) == "\\" and not present.consoleInfo(1)
            and string.rep("-", 32) or "────────────────────────────────",
        columns = present.columns(),
    }, Ui)
end

function Ui:configureDisplay(prepare)
    local display, context = self.context._display, self.context
    if not display then return end
    prepare = prepare and display.format ~= "json" or false
    local stdout_info = present.consoleInfo(1, prepare)
    local stderr_info = present.consoleInfo(2, prepare)
    self.color = present.wantColor(display, context, present.streamIsTTY(1), nil,
        stdout_info and stdout_info.capable)
    self.error_color = present.wantColor(display, context, present.streamIsTTY(2), nil,
        stderr_info and stderr_info.capable)
    self.progress_mode = present.wantProgress(display, context, present.streamIsTTY(2))
    if self.progress_mode == "redraw" and stderr_info and stderr_info.tty and not stderr_info.capable then
        self.progress_mode = "plain"
    end
    self.color_level = present.colorLevel(os.getenv, self.color or self.error_color)
    self.columns = stdout_info and stdout_info.columns or present.columns()
    self.error_columns = stderr_info and stderr_info.columns or present.columns()
    if stdout_info then self.rule = "────────────────────────────────" end
end

local TRUECOLOR = {
    ["1;36"] = "1;38;2;125;211;252",
    ["1;32"] = "1;38;2;74;222;128",
    ["1;33"] = "1;38;2;251;191;36",
    ["1;31"] = "1;38;2;248;113;113",
    ["2"] = "38;2;148;163;184",
    ["1"] = "1;38;2;226;232;240",
    ["36"] = "38;2;56;189;248",
}
local COLOR_256 = {
    ["1;36"] = "1;38;5;117",
    ["1;32"] = "1;38;5;42",
    ["1;33"] = "1;38;5;221",
    ["1;31"] = "1;38;5;203",
    ["2"] = "38;5;246",
    ["1"] = "1;38;5;255",
    ["36"] = "38;5;45",
}

function Ui:paint(code, text, diagnostic)
    text = present.visible(text)
    local enabled = self.color
    if diagnostic and self.error_color ~= nil then enabled = self.error_color end
    if not enabled then
        return text
    end
    local sequence = code
    if self.color_level == "truecolor" then sequence = TRUECOLOR[code] or code end
    if self.color_level == "256" then sequence = COLOR_256[code] or code end
    return string.format("\27[%sm%s\27[0m", sequence, text)
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
    if self.format == "json" or self.progress_mode == "off" then
        return
    end
    if self.progress_mode == "redraw" then
        if self.redraw_stop then return end
        self.redraw_stop, self.redraw_pause = present.startRedraw(label)
        if self.redraw_stop then return end
        self.redraw_pause = nil
    end
    local line = self:paint("36", "|", true) .. " "
        .. present.fit(tostring(label), (self.error_columns or self.columns) - 4)
    present.writeError(line .. "\n")
end

function Ui:clearProgress()
    if self.redraw_pause then self.redraw_pause(); return end
    if self.redraw_stop then
        self.redraw_stop()
        self.redraw_stop = nil
    end
end

function Ui:close()
    if self.redraw_stop then
        local stop = self.redraw_stop
        self.redraw_stop, self.redraw_pause = nil, nil
        stop()
    end
end

local function writeClassicError(message)
    present.writeError(string.format("error: %s\n", present.multiline(message)))
end

local function writeClassicHint(message)
    present.writeError(string.format("try: %s\n", message))
end

local function writeModernError(ui, message)
    local errors = setmetatable({ color = ui.error_color == nil and ui.color or ui.error_color,
        color_level = ui.color_level }, Ui)
    present.writeError(errors:paint("2", ui.rule) .. "\n")
    present.writeError(string.format("%s %s\n", errors:err("error:"), present.multiline(message)))
end

local function writeModernHint(message)
    present.writeError(string.format("%s %s\n", "hint:", message))
end

local function newOptions()
    return {
        include = {},
        ffi_libraries = {},
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

local function parseActionOptions(parser, action)
    local opts = newOptions()
    local explicit_mode
    local selected, conflict = {}, nil
    local function assign(key, value)
        if selected[key] ~= nil and selected[key] ~= value then
            conflict = conflict or ("conflicting values for " .. key:gsub("_", "-"))
        else
            opts[key], selected[key] = value, value
        end
    end
    opts.action = action

    while parser:hasNext() do
        local item = parser:consume()
        if item == "--dir" or item == "--onedir" then
            assign("mode", "onedir")
            explicit_mode = "onedir"
        elseif item == "--file" or item == "--onefile" then
            assign("mode", "onefile")
            explicit_mode = "onefile"
        elseif item == "--file-mode" then
            local value, err = parser:consumeValue(item)
            if not value then return nil, err end
            if value ~= "auto" and value ~= "extract" and value ~= "no-extract" then
                return nil, "--file-mode must be auto, extract, or no-extract"
            end
            assign("onefile_mode", value)
        elseif item == "--no-moon-detect" or item == "-M" then
            opts.moon_detect = false
        elseif item == "-o" or item == "--out" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            assign("out", value)
        elseif item == "--include" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            opts.include[#opts.include + 1] = value
        elseif item == "--ffi-library" then
            local value, err = parser:consumeValue(item)
            if not value then return nil, err end
            local name, filename = value:match("^([^=]+)=(.+)$")
            if not name then return nil, "--ffi-library requires name=path" end
            if opts.ffi_libraries[name] then return nil, "duplicate FFI library name: " .. name end
            opts.ffi_libraries[name] = filename
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
            assign("target_os", value)
        elseif item == "--lua" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            assign("lua", value)
        elseif item == "--lua-prefix" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            assign("lua_prefix", value)
        elseif item == "-d" or item == "--discovery-mode" then
            local value, err = parser:consumeValue(item)
            if not value then
                return nil, err
            end
            assign("discovery_mode", value)
        elseif item == "--no-depscan" then
            opts.depscan = false
            assign("discovery_mode", "manual")
        elseif item == "--max-deps" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            local number, err = parsePositiveInteger(value, item)
            if not number then
                return nil, err
            end
            assign("max_deps", number)
        elseif item == "--runtime-timeout" or item == "--max-source-bytes"
            or item == "--max-bundle-bytes" or item == "--max-trace-bytes" then
            local value, value_err = parser:consumeValue(item)
            if not value then return nil, value_err end
            local number = tonumber(value)
            if not number or number ~= number or number <= 0 or number == math.huge then
                return nil, item .. " must be finite and positive"
            end
            assign(item:sub(3):gsub("-", "_"), number)
        elseif item == "--verbose" then
            opts.verbose = true
        elseif item:match("^%-%-verbose=") or item:match("^%-%-no%-depscan=")
            or item:match("^%-%-dir=") or item:match("^%-%-onedir=")
            or item:match("^%-%-file=") or item:match("^%-%-onefile=")
            or item:match("^%-M=") then
            return nil, (item:match("^(--[%w%-]+)") or item) .. " does not take a value"
        elseif item == "--" then
            while parser:hasNext() do
                opts.run_args[#opts.run_args + 1] = parser:consume(true)
            end
            break
        elseif not opts.entry and item:sub(1, 1) ~= "-" then
            opts.entry = item
        else
            return nil, string.format("unknown option for %s: %s", action, item)
        end
    end

    if conflict then return nil, conflict end
    if not opts.entry then
        return nil, string.format("%s requires an entry script", action)
    end
    if opts.onefile_mode then
        if action ~= "bundle" then return nil, "--file-mode is a build option" end
        if explicit_mode == "onedir" then return nil, "--file-mode cannot be combined with --dir" end
        opts.mode = "onefile"
    end

    return opts
end

local function structuredErrorText(result, verbose)
    local err = result and result.error or {}
    local err_type = err.type or "LuaInstallerError"
    local message = err.message or "operation failed"
    local text = string.format("%s: %s", err_type, message)
    if not verbose then return text end
    local details = {}
    for _, item in ipairs({
        { "command", err.command },
        { "output", err.output },
        { "cause", err.cause },
    }) do
        local value = item[2]
        if type(value) == "string" and value ~= "" then
            details[#details + 1] = item[1] .. ": " .. value:gsub("%s+$", "")
        end
    end
    if #details > 0 then
        text = text .. "\n" .. table.concat(details, "\n")
    end
    return text
end

local function renderClassicVerboseTrace(result)
    present.write(string.format("trace-records: %d\n", #(result.trace or {})))
    for i, item in ipairs(result.trace or {}) do
        present.write(string.format(
            "trace[%d]: %s %s%s%s\n",
            i,
            present.visible(item.requested or "(unknown)"),
            present.visible(item.reason or "unknown"),
            item.selected_path and " -> " or "",
            present.visible(item.selected_path or "")
        ))
    end
end

local function renderClassicAnalyze(result, verbose)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    present.write("ok\n")
    present.write(string.format("entry: %s\n", present.visible(result.entry)))
    present.write(string.format("scripts: %d\n", #deps.scripts))
    present.write(string.format("libraries: %d\n", #deps.libraries))
    for i, path in ipairs(deps.scripts) do
        present.write(string.format("script[%d]: %s\n", i, present.visible(path)))
    end
    for i, path in ipairs(deps.libraries) do
        present.write(string.format("library[%d]: %s\n", i, present.visible(path)))
    end
    if verbose then
        renderClassicVerboseTrace(result)
    end
end

local function renderClassicTrace(result)
    present.write("trace\n")
    present.write(string.format("entry: %s\n", present.visible(result.entry)))
    for i, item in ipairs(result.trace or {}) do
        present.write(string.format(
            "%d: %s %s %s%s%s\n",
            i,
            present.visible(item.classification or item.selected_type or "unknown"),
            present.visible(item.reason or "unknown"),
            present.visible(item.requested or "(unknown)"),
            item.selected_path and " -> " or "",
            present.visible(item.selected_path or "")
        ))
    end
    if result.compatibility then
        present.write(string.format("compatibility: %s\n", present.visible(result.compatibility.summary or "unknown")))
        for _, note in ipairs(result.compatibility.notes or {}) do
            present.write(string.format("note: %s\n", present.visible(note)))
        end
        for _, warning in ipairs(result.compatibility.warnings or {}) do
            present.write(string.format("warning: %s\n", present.visible(warning)))
        end
    end
end

local function renderBundleDiagnostics(result, verbose)
    if verbose and result.toolchain then
        local selected = result.toolchain
        present.write(string.format("toolchain: %s; %s; Lua declarations: %s\n",
            present.visible(selected.source or "unknown"), present.visible(selected.link_mode or "unknown"),
            present.visible(selected.lua_header)))
        present.write(string.format("lua-library: %s\n", present.visible(selected.library_path or "unknown")))
    end
    for _, warning in ipairs(result.warnings or {}) do
        present.writeError("warning: " .. present.multiline(warning.message) .. "\n")
    end
end

local function renderClassicBundle(result, opts)
    present.write("ok\n")
    if result.executable then
        present.write(string.format("executable: %s\n", present.visible(result.executable)))
    end
    if result.onefile_mode then
        present.write(string.format("file-mode: %s\n", result.onefile_mode))
        if opts.verbose and result.selection_reason then
            present.write("selection: " .. present.visible(result.selection_reason) .. "\n")
        end
    end
    if opts.verbose then
        local manifest = result.manifest or {}
        local modules = manifest.modules or {}
        present.write(string.format("mode: %s\n", result.mode or opts.mode or "unknown"))
        present.write(string.format("lua-modules: %d\n", #(modules.lua or {})))
        present.write(string.format("native-modules: %d\n", #(modules.native or {})))
    end
    renderBundleDiagnostics(result, opts.verbose)
end

local function modernRule(ui)
    return ui:paint("2", ui.rule)
end

local function modernField(ui, label, value)
    local shown = present.visible(value)
    present.write(string.format("  %s  %s\n", ui:paint("2", string.format("%-16s", label)), shown))
end

local function modernList(ui, title, rows)
    if #rows == 0 then return end
    present.write("\n" .. ui:paint("1", title) .. "\n")
    for index, row in ipairs(rows) do
        present.write(string.format("  %s  %s\n", ui:paint("2", string.format("%2d", index)), present.visible(row)))
    end
end

local function renderModernAnalyze(ui, result, verbose)
    local deps = result.dependencies or { scripts = {}, libraries = {} }
    present.write(modernRule(ui) .. "\n")
    present.write(ui:heading("Analysis complete") .. "\n")
    present.write(modernRule(ui) .. "\n")
    modernField(ui, "Entry", result.entry or "")
    present.write(string.format("  Lua scripts: %s\n", ui:ok(tostring(#deps.scripts))))
    modernField(ui, "Native libraries", tostring(#deps.libraries))
    modernList(ui, "Scripts", deps.scripts)
    modernList(ui, "Libraries", deps.libraries)
    if verbose then
        present.write("\n" .. ui:paint("1", "Resolution trace") .. "\n")
        for i, item in ipairs(result.trace or {}) do
            present.write(string.format(
                "  %s  %s %s%s%s\n",
                ui:paint("2", string.format("%2d", i)),
                present.visible(item.requested or "(unknown)"),
                present.visible(item.reason or "unknown"),
                item.selected_path and " -> " or "",
                present.visible(item.selected_path or "")
            ))
        end
    end
    present.write(modernRule(ui) .. "\n")
end

local function renderModernTrace(ui, result)
    present.write(modernRule(ui) .. "\n")
    present.write(ui:heading("Dependency trace") .. "\n")
    present.write(modernRule(ui) .. "\n")
    modernField(ui, "Entry", result.entry or "")
    for i, item in ipairs(result.trace or {}) do
        local kind = item.classification or item.selected_type or "unknown"
        present.write(string.format(
            "  %s  %s  %s  %s%s%s\n",
            ui:paint("2", string.format("%2d", i)),
            ui:paint("36", kind),
            present.visible(item.reason or "unknown"),
            present.visible(item.requested or "(unknown)"),
            item.selected_path and " -> " or "",
            present.visible(item.selected_path or "")
        ))
    end
    if result.compatibility then
        present.write("\n" .. ui:heading("Compatibility") .. "\n")
        modernField(ui, "Summary", result.compatibility.summary or "unknown")
        for _, note in ipairs(result.compatibility.notes or {}) do
            present.write(string.format("  %s %s\n", ui:paint("2", "note"), present.visible(note)))
        end
        for _, warning in ipairs(result.compatibility.warnings or {}) do
            present.write(string.format("  %s %s\n", ui:warn("warning:"), present.visible(warning)))
        end
    end
    present.write(modernRule(ui) .. "\n")
end

local function renderModernBundle(ui, result, opts)
    local manifest = result.manifest or {}
    local modules = manifest.modules or {}
    present.write(modernRule(ui) .. "\n")
    present.write(ui:heading("Build complete") .. "\n")
    present.write(modernRule(ui) .. "\n")
    if opts and opts.entry then modernField(ui, "Entry", opts.entry) end
    if result.mode or (opts and opts.mode) then
        modernField(ui, "Mode", result.mode or opts.mode)
    end
    if result.onefile_mode then
        modernField(ui, "File mode", result.onefile_mode)
    end
    if result.selection_reason then
        modernField(ui, "Selection", result.selection_reason)
    end
    modernField(ui, "Lua modules", tostring(#(modules.lua or {})))
    modernField(ui, "Native modules", tostring(#(modules.native or {})))
    if result.executable then
        modernField(ui, "Executable", result.executable)
    end
    present.write(modernRule(ui) .. "\n")
    renderBundleDiagnostics(result, opts.verbose)
end

local function runAction(style, ui, parser, action)
    local opts, err = parseActionOptions(parser, action)
    if not opts then
        if ui.format == "json" then
            present.writeJson(present.envelope(action == "bundle" and "build" or action,
                false, nil, nil, { type = "InvalidOptionsError", message = err }))
            return 1
        end
        if style == "modern" then
            writeModernError(ui, err)
            writeModernHint("run `luainstaller help`")
        else
            writeClassicError(err)
            writeClassicHint("luai -h")
        end
        return 1
    end

    if style == "modern" then ui:configureDisplay(true) end

    local function emitSuccess(result)
        if ui.format == "json" then
            present.writeJson(present.envelope(action == "bundle" and "build" or action,
                true, result, result.warnings))
            return 0
        end
        if action == "analyze" then
            if style == "modern" then renderModernAnalyze(ui, result, opts.verbose)
            else renderClassicAnalyze(result, opts.verbose) end
        elseif action == "trace" then
            if style == "modern" then renderModernTrace(ui, result)
            else renderClassicTrace(result) end
        else
            if style == "modern" then renderModernBundle(ui, result, opts)
            else renderClassicBundle(result, opts) end
        end
        return 0
    end

    local result
    if action == "analyze" then
        ui:progress("Analyzing")
        result = luainstaller.analyze(opts)
        ui:clearProgress()
        if result.ok then return emitSuccess(result) end
    elseif action == "trace" then
        ui:progress("Tracing")
        result = luainstaller.trace(opts)
        ui:clearProgress()
        if result.ok then return emitSuccess(result) end
    elseif action == "bundle" then
        ui:progress("Building")
        result = luainstaller.bundle(opts)
        ui:clearProgress()
        if result.ok then return emitSuccess(result) end
    end

    local code = result and result.error and result.error.type == "InterruptedError" and 130 or 1
    if ui.format == "json" then
        local err = result and result.error or { type = "LuaInstallerError", message = "operation failed" }
        err.suggestion = present.suggestion(err)
        present.writeJson(present.envelope(action == "bundle" and "build" or action, false, nil, nil, err))
        return code
    end
    if style == "modern" then
        writeModernError(ui, structuredErrorText(result, opts.verbose))
        local hint = present.suggestion(result and result.error)
        if hint then writeModernHint(hint) end
    else
        writeClassicError(structuredErrorText(result, opts.verbose))
    end
    return code
end

local function parseLogOptions(parser, style, ui)
    local limit = nil
    local ascending = false
    local level = nil
    local conflict

    while parser:hasNext() do
        local item = parser:consume()
        if item == "--limit" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            local previous = limit
            limit = tonumber(value)
            if not limit or limit ~= limit or limit == math.huge
                or limit <= 0 or limit ~= math.floor(limit) then
                return nil, "--limit must be a positive integer"
            end
            if previous ~= nil and previous ~= limit then conflict = "conflicting values for --limit" end
        elseif item == "--asc" then
            ascending = true
        elseif item == "--level" then
            local value, value_err = parser:consumeValue(item)
            if not value then
                return nil, value_err
            end
            if not VALID_LEVELS[value] then
                return nil, string.format("invalid log level: %s", value)
            end
            if level ~= nil and level ~= value then conflict = "conflicting values for --level" end
            level = value
        else
            return nil, string.format("unknown option for logs: %s", item)
        end
    end

    if conflict then return nil, conflict end
    return {
        limit = limit,
        level = level,
        descending = not ascending,
    }
end

local function runLogs(parser, style, ui)
    local opts, err = parseLogOptions(parser, style, ui)
    if not opts then
        if ui.format == "json" then
            present.writeJson(present.envelope("logs", false, nil, nil, {
                type = "InvalidOptionsError", message = err,
            }))
            return 1
        end
        if style == "modern" then
            writeModernError(ui, err)
        else
            writeClassicError(err)
        end
        return 1
    end

    if style == "modern" then ui:configureDisplay(true) end
    local query = logger.queryLogs(opts)
    if query.status == "unreadable" then
        if ui.format == "json" then
            present.writeJson(present.envelope("logs", false, nil, nil, {
                type = "LogReadError",
                message = "log file is unreadable",
            }))
        elseif style == "modern" then
            writeModernError(ui, "LogReadError: log file is unreadable")
        else
            writeClassicError("LogReadError: log file is unreadable")
        end
        return 1
    end
    local logs = query.logs or {}
    local warnings = {}
    if query.status == "backup" then
        warnings[1] = {type = "LogRecoveryWarning", message = "using recovered log copy"}
        if ui.format ~= "json" then present.writeError("warning: using recovered log copy\n") end
    end
    if #logs == 0 then
        if ui.format == "json" then
            present.writeJson(present.envelope("logs", true, { logs = {}, status = query.status }, warnings))
        else
            present.write(style == "modern" and "No logs found.\n" or "no logs\n")
        end
        return 0
    end
    if ui.format == "json" then
        present.writeJson(present.envelope("logs", true, { logs = logs, status = query.status }, warnings))
        return 0
    end

    if style == "modern" then
        present.write(ui:heading(string.format("Showing %d log(s)", #logs)) .. "\n")
    else
        present.write(string.format("logs: %d\n", #logs))
    end

    for _, entry in ipairs(logs) do
        local ts = entry.timestamp or "unknown"
        local lvl = entry.level or "info"
        local src = entry.source or "unknown"
        local action = entry.action or "unknown"
        local msg = entry.message or ""
        if style == "modern" then
            local level_text = lvl
            if lvl == "error" then level_text = ui:err(lvl)
            elseif lvl == "warning" then level_text = ui:warn(lvl)
            elseif lvl == "success" then level_text = ui:ok(lvl)
            else level_text = ui:paint("36", lvl) end
            present.write(string.format("  %s  %s  %s:%s\n", ui:paint("2", ts), level_text,
                present.visible(src), present.visible(action)))
            if msg ~= "" then
                present.write("      " .. present.multiline(msg):gsub("\n", "\n      ") .. "\n")
            end
        else
            present.write(string.format("%s\t%s\t%s:%s\t%s\n", present.visible(ts), present.visible(lvl),
                present.visible(src), present.visible(action), present.multiline(msg)))
        end
    end
    return 0
end

local function runLuai(args, context)
    local parser = ArgumentParser.new(args)
    local ui = Ui.new({ color = false, animations = false })
    context._ui = ui

    if not parser:hasNext() then
        present.write(string.format("luai %s\n", VERSION))
        return 0
    end

    local command = parser:consume()
    if command == "-h" then
        if parser:hasNext() then
            writeClassicError("help does not take extra arguments")
            return 1
        end
        present.write(LUAI_HELP)
        return 0
    elseif command == "-v" then
        if parser:hasNext() then
            writeClassicError("version does not take extra arguments")
            return 1
        end
        present.write(string.format("luai %s\n", VERSION))
        return 0
    elseif command == "-a" then
        return runAction("classic", ui, parser, "analyze")
    elseif command == "-t" then
        return runAction("classic", ui, parser, "trace")
    elseif command == "-b" then
        return runAction("classic", ui, parser, "bundle")
    elseif command == "-l" then
        return runLogs(parser, "classic", ui)
    end

    writeClassicError(string.format("unknown luai command: %s", command))
    writeClassicHint("luai -h")
    return 1
end

local function versionReport()
    local compat = require("luainstaller.compat")
    local platform = require("luainstaller.platform")
    local runtime = compat.luaVersion()
    local host = platform.detectHost()
    return {
        version = VERSION,
        license = "LGPL-3.0-or-later",
        runtime = runtime.version,
        kind = runtime.kind,
        host = { os = host.os, arch = host.arch },
        project = PROJECT_URL,
    }
end

local function writeModernVersion(ui)
    local report = versionReport()
    if ui.format == "json" then
        present.writeJson(present.envelope("version", true, report))
        return
    end
    present.write(string.format("luainstaller %s  LGPL 3.0 by WaterRun\n", VERSION))
    present.write(string.format("runtime: %s\n", report.runtime or "unknown"))
    present.write(string.format("host: %s %s\n", report.host.os or "unknown", report.host.arch or "unknown"))
    present.write(string.format("project: %s\n", PROJECT_URL))
end

local function runLuainstaller(args, context)
    local display, stripped, display_err = present.takeDisplay(args, KNOWN_VALUE_OPTIONS, KNOWN_OPTION_TOKENS)
    context = context or {}
    if not display then
        if present.jsonRequested(args, KNOWN_VALUE_OPTIONS, KNOWN_OPTION_TOKENS) then
            present.writeJson(present.envelope(present.commandToken(args), false, nil, nil, {
                type = "InvalidOptionsError", message = display_err,
            }))
            return 1
        end
        local ui = Ui.new(context)
        writeModernError(ui, display_err)
        return 1
    end
    context.format = display.format
    context._display = display
    local parser = ArgumentParser.new(stripped)
    local ui = Ui.new(context)
    context._ui = ui
    -- Only validated actions prepare a native host. Help, version and invalid
    -- options remain compiler-free.
    ui:configureDisplay(false)

    local function rejectExtra(label)
        if not parser:hasNext() then return nil end
        local message = label .. " does not take extra arguments"
        if ui.format == "json" then
            present.writeJson(present.envelope(label, false, nil, nil, {
                type = "InvalidOptionsError", message = message,
            }))
        else
            writeModernError(ui, message)
        end
        return 1
    end

    local function writeModernHelp(topic)
        if ui.format == "json" then
            present.writeJson(present.envelope("help", true, { command = topic, text = LUAINSTALLER_HELP }))
            return
        end
        present.write(ui:heading("luainstaller") .. "  " .. ui:paint("2", VERSION) .. "\n")
        present.write(ui:paint("2", "Two commands, one builder. luai stays terse; this entry shows the full result.") .. "\n")
        present.write(modernRule(ui) .. "\n")
        if topic then present.write(ui:paint("1", "Command: " .. topic) .. "\n") end
        present.write(LUAINSTALLER_HELP)
        present.write(modernRule(ui) .. "\n")
    end

    if not parser:hasNext() then
        writeModernHelp(nil)
        return 0
    end

    local command = parser:consume()
    if MODERN_COMMANDS[command] and command ~= "help" then
        local index = parser.pos
        while index <= #parser.args do
            local item = parser.args[index]
            if item == "--" then break end
            if item == "--help" or item == "-h" then
                writeModernHelp(command)
                return 0
            end
            if KNOWN_VALUE_OPTIONS[item] then index = index + 1 end
            index = index + 1
        end
    end
    if command == "help" or command == "-h" or command == "--help" then
        local topic = nil
        if parser:hasNext() then
            topic = parser:consume()
            local extra = rejectExtra("help")
            if extra then return extra end
            if not MODERN_COMMANDS[topic] then
                local message = "unknown help topic: " .. topic
                if ui.format == "json" then
                    present.writeJson(present.envelope("help", false, nil, nil, {
                        type = "InvalidOptionsError", message = message,
                    }))
                else
                    writeModernError(ui, message)
                end
                return 1
            end
        end
        writeModernHelp(topic)
        return 0
    elseif command == "version" or command == "--version" then
        local extra = rejectExtra("version")
        if extra then return extra end
        writeModernVersion(ui)
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

    if ui.format == "json" then
        present.writeJson(present.envelope(command, false, nil, nil, {
            type = "InvalidOptionsError",
            message = "unknown luainstaller command: " .. tostring(command),
        }))
        return 1
    end
    writeModernError(ui, string.format("unknown luainstaller command: %s", command))
    writeModernHint("run `luainstaller help`")
    return 1
end

local M = {}

function M.main(args, context)
    args = args or {}
    context = context or {}

    local call_context = {}
    for key, value in pairs(context) do call_context[key] = value end
    call_context._ui, call_context._display = nil, nil
    local positional = {}
    for i = 1, #args do
        positional[#positional + 1] = args[i]
    end

    local program = detectProgram(call_context)
    local called, code = pcall(function()
        local status
        if program == "luainstaller" then status = runLuainstaller(positional, call_context)
        else status = runLuai(positional, call_context) end
        present.flush()
        return status
    end)
    local cleaned, cleanup_error = pcall(function()
        if call_context._ui then call_context._ui:close() end
    end)
    if called and cleaned then return code end
    local failure = require("luainstaller.result").fromThrown(called and cleanup_error or code, "CLIError").error
    local rendered = pcall(function()
        if program == "luainstaller" and call_context.format == "json" and failure.type ~= "OutputError" then
            present.writeJson(present.envelope(present.commandToken(positional), false, nil, nil, failure))
        else
            writeClassicError(tostring(failure.type) .. ": " .. tostring(failure.message))
        end
    end)
    if not rendered then
        pcall(present.writeError, "error: OutputError: cannot write command output\n")
    end
    return 1
end

local _modname = ...
if _modname ~= "luainstaller.cli" then
    os.exit(M.main(arg) or 0)
end

return M
