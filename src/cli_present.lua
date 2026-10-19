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

local JSON_COMMANDS = {
    analyze = true, trace = true, build = true, logs = true,
    help = true, version = true,
}

function M.jsonRequested(args)
    local index = 1
    while index <= #args do
        local item = tostring(args[index])
        local name, inline = item:match("^(--[%w%-]+)=(.*)$")
        local token = name or item
        if token == "--format" then
            local value = inline
            if value == nil then
                index = index + 1
                value = args[index]
            end
            if value == "json" then return true end
        end
        index = index + 1
    end
    return false
end

function M.commandToken(args)
    for _, item in ipairs(args) do
        if JSON_COMMANDS[item] then return item end
    end
    return "cli"
end

function M.newDisplay()
    return { color = "auto", progress = "auto", format = "text" }
end

local function fail(message)
    return nil, nil, message
end

function M.takeDisplay(args)
    local display = M.newDisplay()
    local rest = {}
    local index = 1
    while index <= #args do
        local item = args[index]
        local name, inline = tostring(item):match("^(--[%w%-]+)=(.*)$")
        local token = name or item
        if token == "--no-color" or token == "--no-progress" then
            if inline ~= nil then
                return fail(token .. " does not take a value")
            end
            if token == "--no-color" then display.color = "never" else display.progress = "off" end
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
            if token == "--color" then display.color = value end
            if token == "--progress" then display.progress = value end
            if token == "--format" then display.format = value end
        else
            rest[#rest + 1] = item
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
        if codepoint < 32 or codepoint == 127 then
            parts[#parts + 1] = string.format("\\x%02X", codepoint)
        else
            parts[#parts + 1] = text:sub(index, next_index - 1)
        end
        index = next_index
    end
    return table.concat(parts)
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
    local function quote(value)
        return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
    end
    local sink = sink_path or "/dev/stderr"
    local script = table.concat({
        "echo $$",
        "i=0",
        "while true; do",
        "  i=$((i + 1))",
        "  case $((i % 4)) in",
        "    1) g='|';;",
        "    2) g='/';;",
        "    3) g='-';;",
        "    *) g='\\';;",
        "  esac",
        "  printf '\\r[%s] %s' \"$g\" \"$LUAI_PROGRESS_LABEL\" > " .. quote(sink),
        "  sleep 0.1",
        "done",
    }, "\n")
    local pipe = io.popen("LUAI_PROGRESS_LABEL=" .. quote(fitted)
        .. " sh -c " .. quote(script), "r")
    if not pipe then return function() end end
    local pid = pipe:read("*l")
    return function()
        if pid and pid:match("^%d+$") then
            os.execute("kill -TERM " .. pid .. " >/dev/null 2>&1")
            os.execute("kill -KILL " .. pid .. " >/dev/null 2>&1")
        end
        pcall(function() pipe:close() end)
        pid = nil
    end
end

function M.streamIsTTY(fd, windows)
    if windows == nil then windows = package.config:sub(1, 1) == "\\" end
    -- cmd.exe has no `[`, and a failed probe would print onto the console.
    if windows then return false end
    if type(fd) ~= "number" or fd < 0 or fd > 9 or fd ~= math.floor(fd) then
        return false
    end
    local called, first = pcall(os.execute, "[ -t " .. tostring(fd) .. " ]")
    return called and M.commandSucceeded(first)
end

function M.wantColor(display, context, stdout_is_tty, windows)
    context = context or {}
    if display and display.format == "json" then return false end
    if display and display.color == "always" then return true end
    if display and display.color == "never" then return false end
    if context.color ~= nil then return context.color and true or false end
    if os.getenv("NO_COLOR") or os.getenv("CI") or os.getenv("TERM") == "dumb" then
        return false
    end
    if windows == nil then windows = package.config:sub(1, 1) == "\\" end
    if windows and not M.windowsVT() then return false end
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
    return '"' .. value:gsub("[%z\1-\31\"\\]", function(char)
        local byte = char:byte()
        if char == '"' or char == "\\" then return "\\" .. char end
        return string.format("\\u%04x", byte)
    end) .. '"'
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
        return string.format("%.14g", value)
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
    io.write(M.encodeJson(value) .. "\n")
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
