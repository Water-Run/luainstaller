--[[
Checked filesystem primitives for luainstaller.

Author:
    WaterRun
File:
    fs.lua
Date:
    2026-07-11
Updated:
    2026-07-11
]]

local process = require("luainstaller.process")
local compat = require("luainstaller.compat")

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(value)
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index)
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local packed = first * 0x10000 + (second or 0) * 0x100 + (third or 0)
        local first_index = compat.rshift(packed, 18) % 64 + 1
        local second_index = compat.rshift(packed, 12) % 64 + 1
        output[#output + 1] = BASE64_ALPHABET:sub(first_index, first_index)
        output[#output + 1] = BASE64_ALPHABET:sub(second_index, second_index)
        output[#output + 1] = second
            and BASE64_ALPHABET:sub(compat.rshift(packed, 6) % 64 + 1, compat.rshift(packed, 6) % 64 + 1)
            or "="
        output[#output + 1] = third
            and BASE64_ALPHABET:sub(packed % 64 + 1, packed % 64 + 1)
            or "="
    end
    return table.concat(output)
end

local function windowsIsRegularFile(path)
    local powershell = process.windowsPowerShellPath()
    if not powershell then
        return false
    end
    local encoded_path = base64Encode(path)
    local script = table.concat({
        "$p=[Text.Encoding]::Default.GetString([Convert]::FromBase64String('",
        encoded_path,
        "'));$i=Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;",
        "if ($null -eq $i) { exit 1 };",
        "if (-not ($i -is [IO.FileInfo])) { exit 1 };",
        "if (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 1 };",
        "if (($i.Attributes -band [IO.FileAttributes]::Device) -ne 0) { exit 1 };",
        "exit 0",
    })
    local ok = process.output(
        'call "' .. powershell .. '" -NoProfile -NonInteractive -Command "' .. script .. '"'
    )
    return ok == true
end

local function operationError(operation, path, detail)
    return string.format(
        "Cannot %s file %s: %s",
        operation,
        tostring(path),
        tostring(detail or "unknown filesystem error")
    )
end

function M.readFile(path)
    local opened, handle, open_err = pcall(io.open, path, "rb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local read_ok, content, read_err = pcall(handle.read, handle, "*a")
    local close_ok, closed, close_err = pcall(handle.close, handle)
    if not read_ok then
        return nil, operationError("read", path, content)
    end
    if content == nil then
        return nil, operationError("read", path, read_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return content
end

function M.isRegularFile(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
        return false
    end
    if IS_WINDOWS then
        return windowsIsRegularFile(path)
    end
    local ok = process.output("test -f " .. process.shellQuote(path))
    return ok == true
end

function M.readRegularFile(path)
    if not M.isRegularFile(path) then
        return nil, operationError("read", path, "path is not a regular file")
    end
    return M.readFile(path)
end

function M.writeFile(path, content)
    if content == nil then
        content = ""
    end
    if type(content) ~= "string" then
        return nil, operationError("write", path, "content must be a string")
    end

    local opened, handle, open_err = pcall(io.open, path, "wb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local write_ok, wrote, write_err = pcall(handle.write, handle, content)
    local flush_ok, flushed, flush_err = pcall(handle.flush, handle)
    local close_ok, closed, close_err = pcall(handle.close, handle)

    if not write_ok then
        return nil, operationError("write", path, wrote)
    end
    if not wrote then
        return nil, operationError("write", path, write_err)
    end
    if not flush_ok then
        return nil, operationError("flush", path, flushed)
    end
    if not flushed then
        return nil, operationError("flush", path, flush_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return true
end

return M
