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
    2026-08-16
]]

local M = {}
local output_counter = 0
local powershell_counter = 0
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(value)
    local output = {}
    value = tostring(value or "")
    for index = 1, #value, 3 do
        local first = value:byte(index)
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local packed = first * 0x10000 + (second or 0) * 0x100 + (third or 0)
        local first_index = math.floor(packed / 0x40000) % 64 + 1
        local second_index = math.floor(packed / 0x1000) % 64 + 1
        output[#output + 1] = BASE64_ALPHABET:sub(first_index, first_index)
        output[#output + 1] = BASE64_ALPHABET:sub(second_index, second_index)
        output[#output + 1] = second
            and BASE64_ALPHABET:sub(math.floor(packed / 0x40) % 64 + 1,
                math.floor(packed / 0x40) % 64 + 1)
            or "="
        output[#output + 1] = third
            and BASE64_ALPHABET:sub(packed % 64 + 1, packed % 64 + 1)
            or "="
    end
    return table.concat(output)
end

local function base64Decode(value)
    local inverse = {}
    for index = 1, #BASE64_ALPHABET do
        inverse[BASE64_ALPHABET:sub(index, index)] = index - 1
    end
    local output = {}
    value = tostring(value or ""):gsub("%s", "")
    if #value % 4 ~= 0 then return nil end
    for index = 1, #value, 4 do
        local first = inverse[value:sub(index, index)]
        local second = inverse[value:sub(index + 1, index + 1)]
        local third_character = value:sub(index + 2, index + 2)
        local fourth_character = value:sub(index + 3, index + 3)
        local third = inverse[third_character] or 0
        local fourth = inverse[fourth_character] or 0
        if first == nil or second == nil
            or (third_character ~= "=" and inverse[third_character] == nil)
            or (fourth_character ~= "=" and inverse[fourth_character] == nil) then
            return nil
        end
        local packed = first * 0x40000 + second * 0x1000 + third * 0x40 + fourth
        output[#output + 1] = string.char(math.floor(packed / 0x10000) % 0x100)
        if third_character ~= "=" then
            output[#output + 1] = string.char(math.floor(packed / 0x100) % 0x100)
        end
        if fourth_character ~= "=" then
            output[#output + 1] = string.char(packed % 0x100)
        end
    end
    return table.concat(output)
end

-- CreateProcess-style argument quoting (backslash/double-quote rules). This
-- is NOT safe for cmd.exe command lines: cmd.exe additionally interprets
-- % ^ & | < > and () metacharacters. Product data paths use the PowerShell
-- ProcessStartInfo backend (outputCommand) or base64-decoded PowerShell
-- expressions, never a raw cmd.exe string built from external data. Callers
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

local function utf16leBase64(ascii)
    local bytes = {}
    for index = 1, #ascii do
        bytes[#bytes + 1] = ascii:sub(index, index)
        bytes[#bytes + 1] = "\0"
    end
    return base64Encode(table.concat(bytes))
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

local function asciiScript(script)
    if type(script) ~= "string" or script == "" or script:find("\0", 1, true) then
        return false
    end
    for index = 1, #script do
        if script:byte(index) > 0x7f then return false end
    end
    return true
end

local function cleanWindowsOutput(output)
    local cleaned, removed = tostring(output):gsub(
        '<Objs Version="1%.1%.0%.1" xmlns="http://schemas%.microsoft%.com/powershell/2004/04">'
            .. '<Obj S="progress".-</Objs>%s*$',
        ""
    )
    if removed > 0 then cleaned = cleaned:gsub("^#< CLIXML\r?\n", "") end
    return cleaned
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

function M.windowsPowerShellPath()
    local root = os.getenv("SystemRoot")
    if type(root) ~= "string" or root == "" then
        root = os.getenv("WINDIR")
    end
    if type(root) ~= "string" or root == "" then
        return nil
    end
    root = root:gsub("/", "\\"):gsub("\\+$", "")
    if not root:match("^%a:\\") or root:find('[%c"%%!%^&|<>]') then
        return nil
    end
    return root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
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
            local ok, _ = M.output("command -v timeout >/dev/null 2>&1")
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

local function powershellInvocation(script, input_format)
    local powershell = M.windowsPowerShellPath()
    if not powershell then return nil, "absolute Windows PowerShell path is unavailable" end
    return table.concat({
        windowsQuote(powershell),
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-InputFormat",
        input_format,
        "-OutputFormat",
        "Text",
        "-EncodedCommand",
        utf16leBase64(script),
    }, " ")
end

function M.outputPowerShell(script)
    if not IS_WINDOWS then return false, "PowerShell execution is available only on Windows" end
    if not asciiScript(script) then
        return false, "PowerShell script must be nonempty ASCII without NUL bytes"
    end
    local invocation, invocation_err = powershellInvocation(script, "Text")
    if not invocation then return false, invocation_err end
    if #invocation > 6000 then
        powershell_counter = powershell_counter + 1
        local parent = os.getenv("TEMP") or os.getenv("TMP")
        if type(parent) ~= "string" or parent == "" or parent:find("\0", 1, true) then
            return false, "a safe Windows temporary directory is unavailable"
        end
        parent = parent:gsub("/", "\\"):gsub("\\+$", "")
        local temporary = parent .. "\\luainstaller-ps-" .. tostring(os.time())
            .. "-" .. tostring(math.floor(os.clock() * 1000000000))
            .. "-" .. tostring(powershell_counter) .. ".ps1"
        local function decodeExpression(value)
            return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
                .. base64Encode(value) .. "'))"
        end
        local write_script = table.concat({
            "$ErrorActionPreference='Stop';$p=", decodeExpression(temporary), ";",
            "$s=New-Object IO.FileStream($p,[IO.FileMode]::CreateNew,",
            "[IO.FileAccess]::Write,[IO.FileShare]::None);",
            "try{$LuaiInput.CopyTo($s);$s.Flush($true)}finally{$s.Dispose()}",
        })
        local wrote, write_err = M.inputPowerShell(write_script, script)
        if not wrote then return false, write_err end
        local run_script = table.concat({
            "$ErrorActionPreference='Stop';$p=", decodeExpression(temporary), ";",
            "$s=[IO.File]::ReadAllText($p,[Text.Encoding]::ASCII);",
            "& ([ScriptBlock]::Create($s))",
        })
        local run_invocation, run_err = powershellInvocation(run_script, "Text")
        if not run_invocation then return false, run_err end
        local ok, output = M.output(run_invocation)
        local remove_script = "$p=" .. decodeExpression(temporary)
            .. ";if([IO.File]::Exists($p)){[IO.File]::Delete($p)}"
        local removed, remove_err = M.outputPowerShell(remove_script)
        if not removed then
            return false, cleanWindowsOutput(output) .. "\n" .. tostring(remove_err)
        end
        return ok, cleanWindowsOutput(output)
    end
    local ok, output = M.output(invocation)
    return ok, cleanWindowsOutput(output)
end

function M.environmentVariable(name)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
        return nil, "environment variable name must be portable"
    end
    if not IS_WINDOWS then return os.getenv(name) end

    -- The narrow CRT getenv() used by Lua 5.1-5.3 returns bytes in the active
    -- Windows code page. Paths then become invalid when the UTF-8 filesystem
    -- bridge consumes those bytes. Read the Unicode process environment and
    -- transport it as ASCII Base64 instead.
    local ok, encoded = M.outputPowerShell(table.concat({
        "$Value=[Environment]::GetEnvironmentVariable('", name, "','Process');",
        "if($null -eq $Value){[Console]::Write('0')}",
        "else{[Console]::Write('1'+[Convert]::ToBase64String(",
        "[Text.Encoding]::UTF8.GetBytes($Value)))}",
    }))
    if not ok then return nil, encoded end
    encoded = tostring(encoded or ""):gsub("%s", "")
    if encoded == "0" then return nil end
    if encoded:sub(1, 1) ~= "1" then
        return nil, "invalid encoded environment response"
    end
    local value = base64Decode(encoded:sub(2))
    if value == nil then return nil, "invalid encoded environment value" end
    return value
end

function M.inputPowerShell(script, input)
    if not IS_WINDOWS then return false, "PowerShell execution is available only on Windows" end
    if not asciiScript(script) then
        return false, "PowerShell script must be nonempty ASCII without NUL bytes"
    end
    if type(input) ~= "string" then return false, "PowerShell input must be a string" end
    local wrapped_script = table.concat({
        "$ErrorActionPreference='Stop';",
        "$LuaiEncoded=[Console]::In.ReadToEnd();",
        "$LuaiBytes=[Convert]::FromBase64String($LuaiEncoded);",
        "$LuaiInput=New-Object IO.MemoryStream(,$LuaiBytes);try{",
        script,
        "}finally{$LuaiInput.Dispose()}",
    })
    local invocation, invocation_err = powershellInvocation(wrapped_script, "None")
    if not invocation then return false, invocation_err end
    local opened, pipe = pcall(io.popen, invocation .. " >NUL 2>&1", "w")
    if not opened or not pipe then return false, tostring(pipe) end
    local wrote, write_result = pcall(pipe.write, pipe, base64Encode(input))
    local flushed, flush_result = pcall(pipe.flush, pipe)
    local closed, close_result = pcall(pipe.close, pipe)
    if not wrote or not write_result then return false, "cannot write PowerShell input" end
    if not flushed or not flush_result then return false, "cannot flush PowerShell input" end
    if not closed or close_result ~= true then return false, "PowerShell input command failed" end
    return true
end

local function windowsOutputCommand(validated, opts)
    opts = opts or {}
    local powershell = M.windowsPowerShellPath()
    if not powershell then return false, "absolute Windows PowerShell path is unavailable" end
    local quoted_arguments = {}
    for _, value in ipairs(validated.arguments) do
        quoted_arguments[#quoted_arguments + 1] = windowsQuote(value)
    end
    local function decodeExpression(value)
        return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
            .. base64Encode(value) .. "'))"
    end
    local timeout_seconds = type(opts.timeout_seconds) == "number"
        and opts.timeout_seconds > 0 and opts.timeout_seconds or nil
    local script = {
        "$ErrorActionPreference='Stop'",
        "$Start=New-Object System.Diagnostics.ProcessStartInfo",
        "$Start.FileName=" .. decodeExpression(validated.executable),
        "$Start.Arguments=" .. decodeExpression(table.concat(quoted_arguments, " ")),
        "$Start.UseShellExecute=$false",
        "$Start.CreateNoWindow=$true",
        "$Start.RedirectStandardOutput=$true",
        "$Start.RedirectStandardError=$true",
        "$Utf8=New-Object Text.UTF8Encoding($false)",
        "$Start.StandardOutputEncoding=[Text.Encoding]::Default",
        "$Start.StandardErrorEncoding=[Text.Encoding]::Default",
    }
    for _, name in ipairs(sortedKeys(validated.environment)) do
        script[#script + 1] = "$Start.EnvironmentVariables[(" .. decodeExpression(name)
            .. ")]=" .. decodeExpression(validated.environment[name])
    end
    script[#script + 1] = "try{$Child=New-Object System.Diagnostics.Process;$Child.StartInfo=$Start;"
        .. "if(-not $Child.Start()){exit 127};$OutTask=$Child.StandardOutput.ReadToEndAsync();"
        .. "$ErrTask=$Child.StandardError.ReadToEndAsync();"
    if timeout_seconds then
        script[#script + 1] = "if(-not $Child.WaitForExit("
            .. tostring(math.floor(timeout_seconds * 1000)) .. ")){"
            .. "$Child.Kill($true);$Child.WaitForExit();"
            .. "[Console]::OutputEncoding=$Utf8;"
            .. "[Console]::Error.Write('luainstaller: command timed out after "
            .. tostring(timeout_seconds) .. "s');exit 124};"
    else
        script[#script + 1] = "$Child.WaitForExit();"
    end
    script[#script + 1] = "$Stdout=$OutTask.Result;$Stderr=$ErrTask.Result;$Code=$Child.ExitCode;"
        .. "[Console]::OutputEncoding=$Utf8;[Console]::Out.Write($Stdout);"
        .. "[Console]::Error.Write($Stderr);exit $Code}catch{[Console]::Error.Write($_.Exception.Message);exit 127}"
    return M.outputPowerShell(table.concat(script, ";"))
end

function M.outputCommand(executable, arguments, environment, opts)
    local validated, validation_err = validateCommand(executable, arguments, environment)
    if not validated then return false, validation_err end
    if IS_WINDOWS then return windowsOutputCommand(validated, opts) end
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
