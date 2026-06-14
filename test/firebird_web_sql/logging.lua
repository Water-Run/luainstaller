--[[
Minimal LuaLogging-compatible shim for packaged Pegasus use.

Pegasus probes `require("logging")` through pcall. Providing this local shim
keeps this sample self-contained when LuaLogging is not installed.

Author:
    WaterRun
File:
    logging.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local M = {
    _VERSION = "LuaLogging shim",
}

local function nop()
end

function M.defaultLogger()
    return setmetatable({}, {
        __index = function(self, key)
            self[key] = nop
            return nop
        end,
    })
end

return M
