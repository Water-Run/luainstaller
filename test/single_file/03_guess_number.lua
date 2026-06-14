--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    03_guess_number.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local secret = 42
local guess = tonumber(arg[1])

if not guess then
    print("Pass a number, for example: lua 03_guess_number.lua 42")
elseif guess < secret then
    print("Too small")
elseif guess > secret then
    print("Too large")
else
    print("Correct")
end
