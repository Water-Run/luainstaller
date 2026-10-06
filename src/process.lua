--[[
Process helpers for luainstaller.
Provides command execution and POSIX shell quoting helpers used by
discovery and bundling code.

Author:
    WaterRun
File:
    process.lua
Date:
    2026-06-27
Updated:
    2026-10-06
]]

local M = {}
local output_counter = 0
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
-- CreateProcess-style argument quoting (backslash/double-quote rules). This
-- is NOT safe for cmd.exe command lines: cmd.exe additionally interprets
-- % ^ & | < > and () metacharacters. Product data paths use the native
-- Win32 process backend (outputCommand), never a raw cmd.exe string built
-- from external data. Callers
-- that build raw strings for M.output on Windows remain responsible for
-- cmd.exe quoting.
local function windowsQuote(value)
    value = tostring(value or "")
    if value == "" then return '""' end
    if not value:find('[%s"]') then return value end
    local output = { '"' }
    local slashes = 0
    for index = 1, #value do
        local character = value:sub(index, index)
        if character == "\\" then
            slashes = slashes + 1
        elseif character == '"' then
            output[#output + 1] = string.rep("\\", slashes * 2 + 1)
            output[#output + 1] = '"'
            slashes = 0
        else
            output[#output + 1] = string.rep("\\", slashes)
            output[#output + 1] = character
            slashes = 0
        end
    end
    output[#output + 1] = string.rep("\\", slashes * 2)
    output[#output + 1] = '"'
    return table.concat(output)
end

local function validateCommand(executable, arguments, environment)
    if type(executable) ~= "string" or executable == "" or executable:find("\0", 1, true) then
        return nil, "executable must be a nonempty string without NUL bytes"
    end
    local copied_arguments = {}
    for index, value in ipairs(arguments or {}) do
        if type(value) ~= "string" or value:find("\0", 1, true) then
            return nil, "command arguments must be strings without NUL bytes"
        end
        copied_arguments[index] = value
    end
    local copied_environment = {}
    for name, value in pairs(environment or {}) do
        if type(name) ~= "string" or not name:match("^[%a_][%w_]*$")
            or type(value) ~= "string" or value:find("\0", 1, true) then
            return nil, "environment entries must have portable names and string values"
        end
        copied_environment[name] = value
    end
    return {
        executable = executable,
        arguments = copied_arguments,
        environment = copied_environment,
    }
end

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function legacyPosixInvocation(command)
    output_counter = output_counter + 1
    local identity = tostring({}):gsub("[^%w]", "")
    local token = string.format(
        "LUAINSTALLER_EXIT_%s_%d_%d",
        identity,
        os.time(),
        output_counter
    )
    local invocation = "(" .. command .. ") 2>&1; "
        .. "__luainstaller_status=$?; printf '\\n" .. token
        .. ":%s\\n' \"$__luainstaller_status\""
    return invocation, token
end

local function legacyWindowsInvocation(command)
    output_counter = output_counter + 1
    local identity = tostring({}):gsub("[^%w]", "")
    local token = string.format(
        "LUAINSTALLER_EXIT_%s_%d_%d",
        identity,
        os.time(),
        output_counter
    )
    local invocation = command .. " 2>&1"
        .. "&call set LUAI_STATUS=^%errorlevel^%"
        .. "&echo."
        .. "&call echo " .. token .. ":^%LUAI_STATUS^%"
    return invocation, token
end

local hasTimeoutUtility
local timeout_utility_available
local posixTimeoutRelay

function M.output(command, opts)
    if type(io.popen) ~= "function" then
        return false, "io.popen is not available in this Lua runtime"
    end
    -- On Windows the command string is interpreted by cmd.exe, whose
    -- metacharacter set differs from CreateProcess quoting (see windowsQuote).
    opts = opts or {}
    local invocation = command .. " 2>&1"
    local legacy_token
    if _VERSION == "Lua 5.1" then
        if IS_WINDOWS then
            invocation, legacy_token = legacyWindowsInvocation(command)
        else
            invocation, legacy_token = legacyPosixInvocation(command)
        end
    end
    if not IS_WINDOWS and type(opts.timeout_seconds) == "number"
        and opts.timeout_seconds > 0 and hasTimeoutUtility() then
        -- Raw shell snippets need timeout's managed process group so a timed
        -- out pipeline cannot leave descendants holding the output pipe.
        local seconds = math.max(1, math.floor(opts.timeout_seconds))
        invocation = "timeout --kill-after=5s "
            .. tostring(seconds) .. "s sh -c " .. M.quote(invocation)
        invocation = posixTimeoutRelay(invocation)
    end
    local ok, pipe = pcall(io.popen, invocation, "r")
    if not ok or not pipe then
        return false, tostring(pipe)
    end
    local output = pipe:read("*a") or ""
    -- pipe:close() succeeds with first result true (Lua 5.1 / 5.2+ / LuaJIT).
    local close_ok = pipe:close()
    if legacy_token then
        local captured, status = output:match(
            "^(.*)\n" .. legacy_token .. ":(%d+)\r?\n?$"
        )
        if not status then
            return false, output
        end
        return tonumber(status) == 0, captured
    end
    if close_ok == true then
        return true, output
    end
    return false, output
end

hasTimeoutUtility = function()
    if timeout_utility_available == nil then
        if IS_WINDOWS then
            timeout_utility_available = false
        else
            -- The implementation below deliberately uses GNU timeout's
            -- --kill-after process-group semantics.  FreeBSD also ships a
            -- command named timeout, but older releases use a different CLI;
            -- treating name presence as capability breaks every compiler
            -- invocation on those hosts.
            local ok, _ = M.output(
                "timeout --kill-after=1s 1s sh -c 'exit 0' >/dev/null 2>&1"
            )
            timeout_utility_available = (ok == true)
        end
    end
    return timeout_utility_available
end

function M.quote(value)
    if IS_WINDOWS then return windowsQuote(value) end
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.command(executable, arguments, environment)
    local validated, validation_err = validateCommand(executable, arguments, environment)
    if not validated then return nil, validation_err end
    local parts = {}
    if not IS_WINDOWS then
        for _, name in ipairs(sortedKeys(validated.environment)) do
            parts[#parts + 1] = name .. "=" .. M.quote(validated.environment[name])
        end
    end
    parts[#parts + 1] = M.quote(validated.executable)
    for _, value in ipairs(validated.arguments) do
        parts[#parts + 1] = M.quote(value)
    end
    return table.concat(parts, " ")
end

-- GNU timeout puts the monitored command in a separate process group.  That
-- is necessary for killing all descendants on expiry, but it also means an
-- interrupt sent to the caller's process group would otherwise leave the
-- monitor (and a compiler below it) running.  Keep this small supervisor in
-- the caller's group and relay catchable termination signals to timeout.
posixTimeoutRelay = function(command)
    local script = table.concat({
        "__luai_timeout_pid=",
        "__luai_timeout_relay() {",
        '  __luai_timeout_signal="$1"',
        '  __luai_timeout_status="$2"',
        '  if test -n "$__luai_timeout_pid"; then',
        '    kill -"$__luai_timeout_signal" "$__luai_timeout_pid" 2>/dev/null || true',
        '    wait "$__luai_timeout_pid" 2>/dev/null || true',
        "  fi",
        '  exit "$__luai_timeout_status"',
        "}",
        "trap '__luai_timeout_relay HUP 129' HUP",
        "trap '__luai_timeout_relay INT 130' INT",
        "trap '__luai_timeout_relay QUIT 131' QUIT",
        "trap '__luai_timeout_relay TERM 143' TERM",
        command .. " &",
        "__luai_timeout_pid=$!",
        'wait "$__luai_timeout_pid"',
        "__luai_timeout_status=$?",
        "__luai_timeout_pid=",
        'exit "$__luai_timeout_status"',
    }, "\n")
    return "sh -c " .. M.quote(script)
end

function M.environmentVariable(name)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
        return nil, "environment variable name must be portable"
    end
    if not IS_WINDOWS then return os.getenv(name) end

    local ok, value, state = require("luainstaller.windows_host").call("env", name)
    if not ok then return nil, value end
    if state == "missing" then return nil end
    return value
end

function M.outputCommand(executable, arguments, environment, opts)
    local validated, validation_err = validateCommand(executable, arguments, environment)
    if not validated then return false, validation_err end
    if IS_WINDOWS then
        local ok, output = require("luainstaller.windows_host").execute(validated.executable,
            validated.arguments, validated.environment, opts and opts.timeout_seconds)
        -- Match the text-mode pipe contract of the other process backends;
        -- filesystem reads remain byte-for-byte native operations.
        return ok, (tostring(output or ""):gsub("\r\n", "\n"))
    end
    opts = opts or {}
    if type(opts.timeout_seconds) == "number" and opts.timeout_seconds > 0
        and hasTimeoutUtility() then
        -- Invoke the validated argv directly, using env(1) only when
        -- overrides are present.  Keep GNU timeout's managed process group:
        -- --foreground explicitly leaves descendants outside timeout's
        -- control, and those descendants can keep io.popen's output pipe open
        -- after the direct child exits.
        local timeout_arguments = {
            "--kill-after=5s",
            tostring(math.max(1, math.floor(opts.timeout_seconds))) .. "s",
        }
        local environment_names = sortedKeys(validated.environment)
        if #environment_names > 0 then
            timeout_arguments[#timeout_arguments + 1] = "env"
            for _, name in ipairs(environment_names) do
                timeout_arguments[#timeout_arguments + 1] = name .. "="
                    .. validated.environment[name]
            end
        end
        timeout_arguments[#timeout_arguments + 1] = validated.executable
        for _, value in ipairs(validated.arguments) do
            timeout_arguments[#timeout_arguments + 1] = value
        end
        local timeout_command, timeout_err = M.command("timeout", timeout_arguments)
        if not timeout_command then return false, timeout_err end
        return M.output(posixTimeoutRelay(timeout_command))
    end
    local command = assert(M.command(
        validated.executable,
        validated.arguments,
        validated.environment
    ))
    return M.output(command, opts)
end

function M.firstLine(command)
    local ok, output = M.output(command)
    if not ok then
        return nil
    end
    local line = output:match("^[^\r\n]+")
    if line and line ~= "" then
        return line
    end
    return nil
end

function M.shellQuote(value)
    return M.quote(value)
end

return M
