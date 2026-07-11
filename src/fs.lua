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

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

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
        local content = M.readFile(path)
        return content ~= nil
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
