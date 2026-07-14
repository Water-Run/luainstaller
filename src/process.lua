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
    2026-07-14
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

function M.output(command)
    if type(io.popen) ~= "function" then
        return false, "io.popen is not available in this Lua runtime"
    end
    local invocation = command .. " 2>&1"
    local legacy_token
    if _VERSION == "Lua 5.1" and package.config:sub(1, 1) ~= "\\" then
        invocation, legacy_token = legacyPosixInvocation(command)
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
            "$i=[Console]::OpenStandardInput();",
            "$s=New-Object IO.FileStream($p,[IO.FileMode]::CreateNew,",
            "[IO.FileAccess]::Write,[IO.FileShare]::None);",
            "try{$i.CopyTo($s);$s.Flush($true)}finally{$s.Dispose()}",
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

function M.inputPowerShell(script, input)
    if not IS_WINDOWS then return false, "PowerShell execution is available only on Windows" end
    if not asciiScript(script) then
        return false, "PowerShell script must be nonempty ASCII without NUL bytes"
    end
    if type(input) ~= "string" then return false, "PowerShell input must be a string" end
    local invocation, invocation_err = powershellInvocation(script, "None")
    if not invocation then return false, invocation_err end
    local opened, pipe = pcall(io.popen, invocation .. " >NUL 2>&1", "wb")
    if not opened or not pipe then return false, tostring(pipe) end
    local wrote, write_result = pcall(pipe.write, pipe, input)
    local flushed, flush_result = pcall(pipe.flush, pipe)
    local closed, close_result = pcall(pipe.close, pipe)
    if not wrote or not write_result then return false, "cannot write PowerShell input" end
    if not flushed or not flush_result then return false, "cannot flush PowerShell input" end
    if not closed or close_result ~= true then return false, "PowerShell input command failed" end
    return true
end

local function windowsOutputCommand(validated)
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
        .. "$ErrTask=$Child.StandardError.ReadToEndAsync();$Child.WaitForExit();"
        .. "$Stdout=$OutTask.Result;$Stderr=$ErrTask.Result;$Code=$Child.ExitCode;"
        .. "[Console]::OutputEncoding=$Utf8;[Console]::Out.Write($Stdout);"
        .. "[Console]::Error.Write($Stderr);exit $Code}catch{[Console]::Error.Write($_.Exception.Message);exit 127}"
    return M.outputPowerShell(table.concat(script, ";"))
end

function M.outputCommand(executable, arguments, environment)
    local validated, validation_err = validateCommand(executable, arguments, environment)
    if not validated then return false, validation_err end
    if IS_WINDOWS then return windowsOutputCommand(validated) end
    local command = assert(M.command(
        validated.executable,
        validated.arguments,
        validated.environment
    ))
    return M.output(command)
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
