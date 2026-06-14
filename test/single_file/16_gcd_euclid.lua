--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    16_gcd_euclid.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local a = tonumber(arg[1]) or 252
local b = tonumber(arg[2]) or 198

local function gcd(x, y)
    x = math.abs(x)
    y = math.abs(y)
    while y ~= 0 do
        x, y = y, x % y
    end
    return x
end

print(string.format("gcd(%d, %d) = %d", a, b, gcd(a, b)))
