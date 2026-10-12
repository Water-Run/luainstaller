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
    2026-10-12
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
    if arguments ~= nil and type(arguments) ~= "table" then return nil, "arguments must be a list" end
    if environment ~= nil and type(environment) ~= "table" then return nil, "environment must be a table" end
    local copied_arguments = {}
    for index, value in ipairs(arguments or {}) do
        if type(value) ~= "string" or value:find("\0", 1, true) then
            return nil, "command arguments must be strings without NUL bytes"
        end
        copied_arguments[index] = value
    end
    for key in pairs(arguments or {}) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #copied_arguments then
            return nil, "arguments must be a dense list"
        end
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

local function statusToken()
    output_counter = output_counter + 1
    return string.format("LUAI_EXIT_%s_%d_%d", tostring({}):gsub("[^%w]", ""), os.time(), output_counter)
end

local function commandOptions(opts)
    opts = opts or {}
    local timeout = opts.timeout_seconds
    if timeout == nil then timeout = tonumber(os.getenv("LUAI_CMD_TIMEOUT") or "30") end
    local limit = opts.max_output_bytes
    if limit == nil then limit = tonumber(os.getenv("LUAI_MAX_OUTPUT_BYTES") or "8388608") end
    if type(timeout) ~= "number" or timeout ~= timeout or timeout <= 0 or timeout > 86400 then
        return nil, "command timeout must be finite and between zero and 86400 seconds"
    end
    if type(limit) ~= "number" or limit ~= limit or limit < 1 or limit > 1073741824
        or limit ~= math.floor(limit) then
        return nil, "command output limit must be an integer between 1 and 1073741824 bytes"
    end
    return {timeout_seconds=timeout, max_output_bytes=limit}
end

-- The shell path bootstraps a trusted compiler and serves filesystem queries
-- before native supervision exists. Runtime code and tool invocations require
-- the native backend. Its watchdog uses only POSIX host tools.
local function bootstrapInvocation(command, opts, token)
    local script = table.concat({
        "__luai_guard=$$",
        "__luai_parent=$PPID",
        "__luai_child=",
        "__luai_watch=",
        "__luai_tree() {",
        '  __luai_targets="$1"',
        "  __luai_pass=0",
        '  while test "$__luai_pass" -lt 32; do',
        [=[    __luai_more=$(LC_ALL=C ps -e -o pid= -o ppid= | awk -v roots="$__luai_targets" 'BEGIN {n=split(roots,a," "); for(i=1;i<=n;i++) r[a[i]]=1} r[$2] && !r[$1] {print $1}')]=],
        '    test -n "$__luai_more" || break',
        '    __luai_targets="$__luai_targets $__luai_more"',
        "    __luai_pass=$((__luai_pass + 1))",
        "  done",
        '  for __luai_pid in $__luai_targets; do kill -KILL "$__luai_pid" 2>/dev/null || true; done',
        "}",
        "__luai_stop() {",
        [[  trap '' HUP INT QUIT TERM USR1 USR2]],
        '  test -z "$__luai_child" || __luai_tree "$__luai_child"',
        '  test -z "$__luai_watch" || __luai_tree "$__luai_watch"',
        "  printf '\\n" .. token .. ":%s:%s\\n' \"$1\" \"$2\"",
        '  exit "$1"',
        "}",
        "trap '__luai_stop 129 signal' HUP",
        "trap '__luai_stop 130 signal' INT",
        "trap '__luai_stop 131 signal' QUIT",
        "trap '__luai_stop 143 signal' TERM",
        "trap '__luai_stop 124 timeout' USR1",
        "trap '__luai_stop 126 owner-exit' USR2",
        "printf '" .. token .. ":PID:%s\\n' \"$$\"",
        "(" .. command .. ") 2>&1 &",
        "__luai_child=$!",
        "(",
        "  trap 'exit 0' TERM",
        "  __luai_elapsed=0",
        "  while test \"$__luai_elapsed\" -lt " .. tostring(math.ceil(opts.timeout_seconds)) .. "; do",
        "    sleep 1 &",
        "    __luai_nap=$!",
        '    wait "$__luai_nap"',
        '    if ! kill -0 "$__luai_parent" 2>/dev/null; then kill -USR2 "$__luai_guard" 2>/dev/null; exit; fi',
        "    __luai_elapsed=$((__luai_elapsed + 1))",
        "  done",
        '  kill -USR1 "$__luai_guard" 2>/dev/null',
        ") >/dev/null 2>&1 &",
        "__luai_watch=$!",
        'wait "$__luai_child"',
        "__luai_status=$?",
        "__luai_child=",
        -- The watcher may not have installed its trap when a fast command
        -- finishes. Kill this unreaped child directly, then collect its status.
        'kill -KILL "$__luai_watch" 2>/dev/null || true',
        'wait "$__luai_watch" 2>/dev/null || true',
        "__luai_watch=",
        "printf '\\n" .. token .. ":%s:exit\\n' \"$__luai_status\"",
        'exit "$__luai_status"',
    }, "\n")
    return "exec sh -c " .. M.quote(script)
end

local function readPipe(invocation, token, opts, bootstrap)
    local opened, pipe = pcall(io.popen, invocation, "r")
    if not opened or not pipe then return false, tostring(pipe), {reason="supervisor-error"} end
    local guardian, oversized, parts, total = nil, false, {}, 0
    local called, thrown = pcall(function()
        if bootstrap then
            local line = pipe:read("*l")
            guardian = line and line:match("^" .. token .. ":PID:(%d+)$")
            if not guardian then error("process supervisor did not identify its owner", 0) end
        end
        while true do
            local chunk = pipe:read(8192)
            if not chunk then break end
            local accepted = math.min(#chunk, math.max(0, opts.max_output_bytes + 256 - total))
            if accepted > 0 then parts[#parts + 1] = chunk:sub(1, accepted); total = total + accepted end
            if accepted < #chunk and not oversized then
                oversized = true
                if guardian then os.execute("kill -TERM " .. guardian .. " 2>/dev/null") end
            end
        end
    end)
    if not called and guardian then
        os.execute("kill -INT " .. guardian .. " 2>/dev/null")
    end
    local closed, close_result = pcall(pipe.close, pipe)
    if not called then error(thrown, 0) end
    local output = table.concat(parts)
    if oversized then return false, output, {code=125, reason="output-limit"} end
    local captured, code, reason = output:match("^(.*)\n" .. token .. ":(%d+):([a-z%-]+)\r?\n?$")
    if not code or not closed then return false, output, {reason="supervisor-error"} end
    code = tonumber(code)
    if reason == "timeout" then captured = captured .. "\nluainstaller: command timed out" end
    if reason == "output-limit" then captured = captured .. "\nluainstaller: command output limit exceeded" end
    return code == 0 and (close_result == true or _VERSION == "Lua 5.1"), captured, {code=code, reason=reason}
end

local gnu_timeout

local function gnuBootstrapInvocation(command, opts, token)
    local script = table.concat({
        "__luai_timeout_pid=",
        "__luai_stop() {",
        "  trap '' HUP INT QUIT TERM",
        '  test -z "$__luai_timeout_pid" || kill -TERM "$__luai_timeout_pid" 2>/dev/null',
        '  test -z "$__luai_timeout_pid" || wait "$__luai_timeout_pid" 2>/dev/null',
        '  exit "$1"',
        "}",
        "trap '__luai_stop 129' HUP",
        "trap '__luai_stop 130' INT",
        "trap '__luai_stop 131' QUIT",
        "trap '__luai_stop 143' TERM",
        "printf '" .. token .. ":PID:%s\\n' \"$$\"",
        M.quote(gnu_timeout) .. " --signal=TERM --kill-after=1 " .. tostring(opts.timeout_seconds)
            .. " sh -c " .. M.quote(command) .. " 2>&1 &",
        "__luai_timeout_pid=$!",
        'wait "$__luai_timeout_pid"',
        "__luai_status=$?",
        "__luai_timeout_pid=",
        "__luai_reason=exit",
        'test "$__luai_status" -ne 124 || __luai_reason=timeout',
        "printf '\\n" .. token .. ":%s:%s\\n' \"$__luai_status\" \"$__luai_reason\"",
        'exit "$__luai_status"',
    }, "\n")
    return "exec sh -c " .. M.quote(script)
end

local function bootstrapOutput(command, opts)
    local normalized, err = commandOptions(opts)
    if not normalized then return false, err, {reason="invalid-options"} end
    if gnu_timeout == nil then
        gnu_timeout = false
        local probe_opts = {
            timeout_seconds=math.min(30, normalized.timeout_seconds),
            max_output_bytes=4096,
        }
        local probe_token = statusToken()
        local found, location = readPipe(bootstrapInvocation("command -v timeout", probe_opts,
            probe_token), probe_token, probe_opts, true)
        location = tostring(location or ""):match("^%s*(.-)%s*$")
        if found and location:sub(1, 1) == "/" and not location:find("[%c]") then
            local version_token = statusToken()
            local checked, version = readPipe(bootstrapInvocation(M.quote(location) .. " --version",
                probe_opts, version_token), version_token, probe_opts, true)
            if checked and version:find("timeout (GNU coreutils)", 1, true) then gnu_timeout = location end
        end
    end
    local token = statusToken()
    local invocation = gnu_timeout and gnuBootstrapInvocation(command, normalized, token)
        or bootstrapInvocation(command, normalized, token)
    return readPipe(invocation, token, normalized, true)
end

function M.currentPid()
    if IS_WINDOWS then
        local ok, pid = require("luainstaller.windows_host").call("pid")
        return ok and pid or nil
    end
    -- This fixed shell builtin executes directly below Lua; a supervisor would
    -- add another parent and therefore report the wrong owner.
    local opened, pipe = pcall(io.popen, [[printf '%s' "$PPID"]], "r")
    if not opened or not pipe then return nil end
    local read, pid = pcall(pipe.read, pipe, 32)
    local closed, result = pcall(pipe.close, pipe)
    if read and closed and result and tostring(pid):match("^%d+$") then return pid end
    return nil
end

function M.output(command, opts)
    if type(command) ~= "string" or command:find("\0", 1, true) then
        return false, "command must be a string without NUL bytes", {reason="invalid-options"}
    end
    if IS_WINDOWS then return M.outputCommand("cmd.exe", {"/d", "/s", "/c", command}, {}, opts) end
    local native = require("luainstaller.posix_host")
    if not native.ready() and not (opts and opts.timeout_seconds) then return bootstrapOutput(command, opts) end
    return M.outputCommand("sh", {"-c", command}, {}, opts)
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
    if not validated then return false, validation_err, {reason="invalid-options"} end
    local normalized, option_err = commandOptions(opts)
    if not normalized then return false, option_err, {reason="invalid-options"} end
    if IS_WINDOWS then
        local ok, output, extra = require("luainstaller.windows_host").execute(validated.executable,
            validated.arguments, validated.environment, normalized.timeout_seconds, normalized.max_output_bytes)
        local code, reason = tostring(extra or ""):match("^(%d+):([a-z%-]+)$")
        return ok, (tostring(output or ""):gsub("\r\n", "\n")),
            {code=tonumber(code or extra), reason=reason or "exit",
                timeout_seconds=normalized.timeout_seconds, max_output_bytes=normalized.max_output_bytes}
    end
    local token = statusToken()
    local invocation, err = require("luainstaller.posix_host").invocation(validated.executable,
        validated.arguments, validated.environment, normalized, token, bootstrapOutput, M.quote)
    if not invocation then return false, err, {reason="supervisor-unavailable"} end
    local ok, output, status = readPipe(invocation, token, normalized, true)
    status.timeout_seconds, status.max_output_bytes = normalized.timeout_seconds, normalized.max_output_bytes
    return ok, output, status
end

function M.prepareNative()
    if IS_WINDOWS then return require("luainstaller.windows_host").call("pid") end
    local binary, err = require("luainstaller.posix_host").prepare(bootstrapOutput, M.quote)
    return binary ~= nil, err
end

function M.nativeOperation(operation, arguments)
    if IS_WINDOWS then
        return require("luainstaller.windows_host").call(operation, (table.unpack or unpack)(arguments or {}))
    end
    local native = require("luainstaller.posix_host")
    local binary, err = native.prepare(bootstrapOutput, M.quote)
    if not binary then return false, err end
    local command_arguments = {operation}
    for _, value in ipairs(arguments or {}) do command_arguments[#command_arguments + 1] = value end
    return M.outputCommand(binary, command_arguments, {}, {timeout_seconds=10, max_output_bytes=65536})
end

function M.guardOutputParents(value, previous)
    local absolute = require("luainstaller.path").absolute(value)
    local ok, output = M.nativeOperation("output_parents", {absolute})
    if not ok then return nil, output end
    local records = {}
    for record in tostring(output):gmatch("[^\r\n]+") do records[#records + 1] = record end
    if previous then
        for index, record in ipairs(previous) do
            if records[index] ~= record then return nil, "output ancestor changed during the build" end
        end
    end
    return records
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
