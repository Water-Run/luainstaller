--[[
Structured result helpers for luainstaller.
Provides shared construction for public-style error result tables.

Author:
    WaterRun
File:
    result.lua
Date:
    2026-06-27
Updated:
    2026-06-27
]]

local M = {}

function M.error(err_type, message, details)
    local err = {
        type = err_type,
        message = message,
    }
    if details then
        for k, v in pairs(details) do
            err[k] = v
        end
    end
    return {
        ok = false,
        error = err,
    }
end

function M.fromThrown(err, default_type)
    default_type = default_type or "LuaInstallerError"
    if type(err) == "table" then
        return M.error(err.type or default_type, err.message or tostring(err), err)
    end
    return M.error(default_type, tostring(err))
end

return M
