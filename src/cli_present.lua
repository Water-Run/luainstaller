--[[
Display policy, JSON results, and bounded progress for the CLI.

Author:
    WaterRun
File:
    cli_present.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local M = {}
local original_write, original_stderr = io.write, io.stderr
local windows = package.config:sub(1, 1) == "\\"

-- A table field cannot store nil, so missing JSON values use this sentinel.
M.NULL = {}

local VALUE_OPTIONS = {
    ["--color"] = true,
    ["--progress"] = true,
    ["--format"] = true,
}

local COLOR_VALUES = { auto = true, always = true, never = true }
local PROGRESS_VALUES = { auto = true, plain = true, off = true }
local FORMAT_VALUES = { text = true, json = true }

local function optionParts(item)
    local name, inline = tostring(item):match("^(--[%w%-]+)=(.*)$")
    return name or item, inline
end

local function knownOption(item, options)
    local token = optionParts(item)
    return VALUE_OPTIONS[token] or token == "--no-color" or token == "--no-progress"
        or (options and options[token])
end

local function opaqueValue(args, index, values, options)
    local token, inline = optionParts(args[index])
    return inline == nil and values and values[token] and args[index + 1] ~= nil
        and not knownOption(args[index + 1], options)
end

function M.jsonRequested(args, values, options)
    local index = 1
    while index <= #args do
        local token, inline = optionParts(args[index])
        if token == "--" then break end
        if token == "--format" then
            local value = inline
            if value == nil then
                index = index + 1
                value = args[index]
            end
            if value == "json" then return true end
        elseif opaqueValue(args, index, values, options) then
            index = index + 1
        end
        index = index + 1
    end
    return false
end

function M.commandToken(args)
    local index = 1
    while index <= #args do
        local token, inline = optionParts(args[index])
        if token == "--" then break end
        if VALUE_OPTIONS[token] then
            if inline == nil then index = index + 1 end
        elseif token ~= "--no-color" and token ~= "--no-progress" then
            return token
        end
        index = index + 1
    end
    return "cli"
end

function M.newDisplay()
    return { color = "auto", progress = "auto", format = "text" }
end

local function fail(message)
    return nil, nil, message
end

function M.takeDisplay(args, values, options)
    local display = M.newDisplay()
    local rest = {}
    local selected = {}
    local function assign(key, value)
        if selected[key] ~= nil and selected[key] ~= value then
            return "conflicting values for --" .. key
        end
        display[key], selected[key] = value, value
        return nil
    end
    local index = 1
    while index <= #args do
        local item = args[index]
        local token, inline = optionParts(item)
        if token == "--" then
            for remaining = index, #args do rest[#rest + 1] = args[remaining] end
            break
        elseif token == "--no-color" or token == "--no-progress" then
            if inline ~= nil then
                return fail(token .. " does not take a value")
            end
            local err = token == "--no-color" and assign("color", "never") or nil
            if token == "--no-progress" then err = assign("progress", "off") end
            if err then return fail(err) end
        elseif VALUE_OPTIONS[token] then
            local value = inline
            if value == nil then
                index = index + 1
                value = args[index]
                if value == nil then
                    return fail(token .. " requires a value")
                end
            end
            if token == "--color" and not COLOR_VALUES[value] then
                return fail("--color must be auto, always, or never")
            end
            if token == "--progress" and not PROGRESS_VALUES[value] then
                return fail("--progress must be auto, plain, or off")
            end
            if token == "--format" and not FORMAT_VALUES[value] then
                return fail("--format must be text or json")
            end
            local err = assign(token:sub(3), value)
            if err then return fail(err) end
        else
            rest[#rest + 1] = item
            if opaqueValue(args, index, values, options) then
                index = index + 1
                rest[#rest + 1] = args[index]
            end
        end
        index = index + 1
    end
    if display.format == "json" then
        display.color = "never"
        display.progress = "off"
    end
    return display, rest
end

function M.commandSucceeded(status)
    return status == true or status == 0
end

function M.colorLevel(getenv, enabled)
    getenv = getenv or os.getenv
    if not enabled then return "none" end
    local colorterm = getenv("COLORTERM") or ""
    if colorterm == "truecolor" or colorterm == "24bit" then return "truecolor" end
    local term = getenv("TERM") or ""
    if term:find("256color", 1, true) or term:find("alacritty", 1, true) then return "256" end
    return "16"
end

function M.windowsVT(getenv)
    getenv = getenv or os.getenv
    local function present(name)
        local value = getenv(name)
        return type(value) == "string" and value ~= ""
    end
    if present("ANSICON") or present("WT_SESSION") then return true end
    if getenv("ConEmuANSI") == "ON" then return true end
    local term = getenv("TERM") or ""
    if term:find("xterm", 1, true) or term:find("256color", 1, true)
        or term:find("alacritty", 1, true) or term:find("tmux", 1, true) then
        return true
    end
    return false
end

local function codepointWidth(codepoint)
    if codepoint < 32 or codepoint == 127 then return 4 end
    if (codepoint >= 0x0300 and codepoint <= 0x036F)
        or (codepoint >= 0x20D0 and codepoint <= 0x20FF)
        or (codepoint >= 0xFE20 and codepoint <= 0xFE2F) then
        return 0
    end
    if (codepoint >= 0x1100 and codepoint <= 0x115F)
        or codepoint == 0x2329 or codepoint == 0x232A
        or (codepoint >= 0x2E80 and codepoint <= 0xA4CF and codepoint ~= 0x303F)
        or (codepoint >= 0xAC00 and codepoint <= 0xD7A3)
        or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
        or (codepoint >= 0xFE10 and codepoint <= 0xFE19)
        or (codepoint >= 0xFE30 and codepoint <= 0xFE6F)
        or (codepoint >= 0xFF00 and codepoint <= 0xFF60)
        or (codepoint >= 0xFFE0 and codepoint <= 0xFFE6)
        or (codepoint >= 0x1F300 and codepoint <= 0x1F64F)
        or (codepoint >= 0x1F900 and codepoint <= 0x1F9FF)
        or (codepoint >= 0x20000 and codepoint <= 0x3FFFD) then
        return 2
    end
    return 1
end

-- Lua 5.1, Lua 5.2, and LuaJIT have no utf8 library. Invalid sequences stay one byte.
local function nextCodepoint(text, index)
    local lead = text:byte(index)
    if not lead or lead < 0x80 then return lead or 0, index + 1 end
    local length, value, minimum
    if lead <= 0xDF then
        if lead < 0xC2 then return lead, index + 1 end
        length, value, minimum = 2, lead % 32, 0x80
    elseif lead <= 0xEF then
        length, value, minimum = 3, lead % 16, 0x800
    elseif lead <= 0xF4 then
        length, value, minimum = 4, lead % 8, 0x10000
    else
        return lead, index + 1
    end
    for offset = 1, length - 1 do
        local byte = text:byte(index + offset)
        if not byte or byte < 0x80 or byte > 0xBF then
            return lead, index + 1
        end
        value = value * 64 + (byte % 64)
    end
    if value < minimum or value > 0x10FFFF
        or (value >= 0xD800 and value <= 0xDFFF) then
        return lead, index + 1
    end
    return value, index + length
end

function M.displayWidth(text)
    text = tostring(text or "")
    local width, index = 0, 1
    while index <= #text do
        local codepoint, next_index = nextCodepoint(text, index)
        width = width + codepointWidth(codepoint)
        index = next_index
    end
    return width
end

function M.visible(text)
    text = tostring(text or "")
    local parts, index = {}, 1
    while index <= #text do
        local codepoint, next_index = nextCodepoint(text, index)
        if codepoint < 32 or codepoint == 127
            or (codepoint >= 128 and next_index == index + 1) then
            parts[#parts + 1] = string.format("\\x%02X", codepoint)
        else
            parts[#parts + 1] = text:sub(index, next_index - 1)
        end
        index = next_index
    end
    return table.concat(parts)
end

function M.multiline(text)
    return (tostring(text or ""):gsub("[^\n]+", M.visible))
end

function M.fit(text, columns)
    text = M.visible(text)
    columns = tonumber(columns) or 80
    if columns < 4 then columns = 4 end
    if M.displayWidth(text) <= columns then return text end
    local kept, width, index = {}, 0, 1
    while index <= #text do
        local codepoint, next_index = nextCodepoint(text, index)
        local piece = codepoint < 32 or codepoint == 127
            and string.format("\\x%02X", codepoint) or text:sub(index, next_index - 1)
        local piece_width = codepointWidth(codepoint)
        if width + piece_width > columns - 1 then break end
        kept[#kept + 1] = piece
        width = width + piece_width
        index = next_index
    end
    return table.concat(kept) .. "…"
end

function M.columns()
    local columns = tonumber(os.getenv("COLUMNS"))
    if not columns or columns < 20 or columns > 1000 then return 80 end
    return math.floor(columns)
end

local SPINNER = { "|", "/", "-", "\\" }

function M.progressFrame(index, label, columns)
    local glyph = SPINNER[(index % #SPINNER) + 1]
    local room = (columns or M.columns()) - 4
    return string.format("[%s] %s", glyph, M.fit(label, room))
end

function M.startRedraw(label, sink_path)
    local fitted = M.fit(label, M.columns() - 4)
    if windows then
        local host = require("luainstaller.windows_host")
        local ok, token = host.call("progress_start", fitted)
        if not ok then return nil, token end
        local stopped, paused = false, false
        return function()
            if stopped then return end
            stopped = true
            local closed, err = host.call("progress_stop", token)
            if not closed then error({ type = "OutputError", message = err }) end
        end, function()
            if stopped or paused then return end
            local cleared, err = host.call("progress_pause", token)
            if not cleared then error({ type = "OutputError", message = err }) end
            paused = true
        end
    end
    local process = require("luainstaller.process")
    local prepared, err = process.prepareNative()
    if not prepared then return nil, err end
    local binary = require("luainstaller.posix_host").ready()
    if not binary then return nil, "native progress helper is unavailable" end
    local owner = process.currentPid()
    if not owner then return nil, "cannot identify progress owner" end
    local command = "exec " .. process.quote(binary) .. " progress " .. process.quote(owner)
        .. " " .. process.quote(fitted)
    if sink_path then command = command .. " " .. process.quote(sink_path) end
    local pipe = io.popen(command, "w")
    if not pipe then return nil, "cannot start progress display" end
    return function()
        if not pipe then return end
        local closing = pipe
        pipe = nil
        pcall(function() closing:close() end)
    end
end

function M.consoleInfo(fd, prepare)
    if not windows then return nil end
    local host = require("luainstaller.windows_host")
    local call = prepare and host.call or host.peek
    local ok, output = call("console_info", tostring(fd))
    if not ok then return nil end
    local mode, columns, capable = output:match("^console:(%d+):(%d+):(%d+)$")
    return { tty = mode ~= nil, columns = tonumber(columns), capable = capable == "1" }
end

function M.streamIsTTY(fd, is_windows)
    if is_windows == nil then is_windows = windows end
    if is_windows then
        local info = M.consoleInfo(fd)
        return info and info.tty or false
    end
    if type(fd) ~= "number" or fd < 0 or fd > 9 or fd ~= math.floor(fd) then
        return false
    end
    local called, first = pcall(os.execute, "[ -t " .. tostring(fd) .. " ]")
    return called and M.commandSucceeded(first)
end

function M.wantColor(display, context, stdout_is_tty, is_windows, capable)
    context = context or {}
    if display and display.format == "json" then return false end
    if display and display.color == "always" then return true end
    if display and display.color == "never" then return false end
    if context.color ~= nil then return context.color and true or false end
    if os.getenv("NO_COLOR") or os.getenv("CI") or os.getenv("TERM") == "dumb" then
        return false
    end
    if is_windows == nil then is_windows = windows end
    if is_windows and (capable == false or (capable == nil and not M.windowsVT())) then return false end
    return stdout_is_tty and true or false
end

function M.wantProgress(display, context, stderr_is_tty)
    if display and display.format == "json" then return "off" end
    local mode = display and display.progress or "auto"
    if mode == "off" or mode == "plain" then return mode end
    if context and context.animations ~= nil then
        return context.animations and "plain" or "off"
    end
    if os.getenv("CI") or os.getenv("TERM") == "dumb" or not stderr_is_tty then
        return "off"
    end
    return "redraw"
end

local function encodeString(value)
    local parts, index = {'"'}, 1
    while index <= #value do
        local codepoint, next_index = nextCodepoint(value, index)
        local char = value:sub(index, next_index - 1)
        if char == '"' or char == "\\" then
            parts[#parts + 1] = "\\" .. char
        elseif codepoint < 32 or (codepoint >= 128 and next_index == index + 1) then
            parts[#parts + 1] = string.format("\\u%04x", codepoint)
        else
            parts[#parts + 1] = char
        end
        index = next_index
    end
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function encode(value, seen)
    if value == M.NULL then return "null" end
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if type(math.type) == "function" and math.type(value) == "integer" then
            return tostring(value)
        end
        return (string.format("%.17g", value):gsub(",", "."))
    end
    if kind == "string" then return encodeString(value) end
    if kind ~= "table" then return "null" end
    if seen[value] then return "null" end
    seen[value] = true
    local parts = {}
    if isArray(value) then
        for index = 1, #value do
            parts[#parts + 1] = encode(value[index], seen)
        end
        seen[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = encodeString(key) .. ":" .. encode(value[key], seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.encodeJson(value)
    return encode(value, {})
end

function M.envelope(command, ok, result, warnings, err)
    return {
        schema_version = 1,
        command = command,
        ok = ok and true or false,
        result = result == nil and M.NULL or result,
        warnings = warnings or {},
        error = err == nil and M.NULL or err,
    }
end

function M.writeJson(value)
    M.write(M.encodeJson(value) .. "\n")
end

local function write(stream, value)
    value = tostring(value)
    local native = windows and (stream == 1 and io.write == original_write
        or stream == 2 and io.stderr == original_stderr)
    local info = native and M.consoleInfo(stream)
    if info and info.tty then
        local ok, err = require("luainstaller.windows_host").peek("console_write", tostring(stream), value)
        if not ok then error({ type = "OutputError", message = tostring(err) }) end
        return true
    end
    local ok, err
    if stream == 1 then ok, err = io.write(value) else ok, err = io.stderr:write(value) end
    -- Test and embedding writers may return no value on success.
    if ok == nil and err ~= nil then error({ type = "OutputError", message = tostring(err) }) end
    return ok
end

function M.write(value) return write(1, value) end
function M.writeError(value) return write(2, value) end

function M.flush()
    for _, stream in ipairs({ io.stdout, io.stderr }) do
        if type(stream.flush) == "function" then
            local ok, err = stream:flush()
            if ok == nil and err ~= nil then error({ type = "OutputError", message = tostring(err) }) end
        end
    end
end

function M.suggestion(err)
    if type(err) ~= "table" then return nil end
    if err.type == "CompilationFailedError" then
        return "rerun with --verbose to see the compiler command"
    end
    if err.type == "DependencyLimitExceededError" then
        return "raise --max-deps or narrow the inputs with --exclude"
    end
    if err.type == "ResourceLimitExceededError" then
        return "raise the matching byte or time limit"
    end
    if err.cleanup_path and err.committed then
        return "the published output remains; remove the cleanup path after checking it"
    end
    if err.cleanup_path then
        return "a private workspace may remain at the cleanup path"
    end
    return nil
end

function M.newProgress(opts)
    opts = opts or {}
    return {
        mode = opts.mode or "off",
        clock = opts.clock or os.clock,
        interval = opts.interval or (1 / 12),
        last = nil,
        events = {},
        rendered = 0,
        write = opts.write,
    }
end

function M.progressEvent(progress, event)
    progress.events[#progress.events + 1] = event
    local terminal = event.state == "success" or event.state == "error"
        or event.state == "warning"
    local now = progress.clock()
    if progress.last and not terminal and (now - progress.last) < progress.interval then
        return false
    end
    progress.last = now
    progress.rendered = progress.rendered + 1
    if progress.mode == "off" or not progress.write then
        return true
    end
    local line = string.format("%s %s", event.state or "running", event.phase or "work")
    if event.done and event.total then
        line = string.format("%s %d/%d", line, event.done, event.total)
    end
    progress.write(line .. (progress.mode == "plain" and "\n" or "\r"))
    return true
end

return M
