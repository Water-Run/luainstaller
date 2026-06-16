--[[
Runtime bundle greeter fixture.

Author:
    WaterRun
File:
    greeter.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

function M.message(name)
    return "hello " .. tostring(name or "runtime")
end

return M
