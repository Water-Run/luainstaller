--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    15_recursive_factorial.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local n = tonumber(arg[1]) or 6

local function factorial(value)
    if value <= 1 then
        return 1
    end
    return value * factorial(value - 1)
end

print(string.format("%d! = %d", n, factorial(n)))
