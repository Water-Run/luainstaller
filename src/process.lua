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
    2026-07-11
]]

local M = {}
local output_counter = 0

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
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

return M
