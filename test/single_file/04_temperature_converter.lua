--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    04_temperature_converter.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local celsius = tonumber(arg[1]) or 25
local fahrenheit = celsius * 9 / 5 + 32
local kelvin = celsius + 273.15

print(string.format("%.2f C = %.2f F = %.2f K", celsius, fahrenheit, kelvin))
