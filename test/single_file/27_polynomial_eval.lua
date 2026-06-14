--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    27_polynomial_eval.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local coefficients = { 2, -6, 2, -1 }
local x = tonumber(arg[1]) or 3
local value = 0

for _, coefficient in ipairs(coefficients) do
    value = value * x + coefficient
end

print(string.format("p(%s) = %s", x, value))
