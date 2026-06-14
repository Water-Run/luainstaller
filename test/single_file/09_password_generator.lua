--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    09_password_generator.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local length = tonumber(arg[1]) or 12
local seed = tonumber(arg[2]) or 20260612
local out = {}

math.randomseed(seed)
for i = 1, length do
    local n = math.random(#alphabet)
    out[i] = alphabet:sub(n, n)
end

print(table.concat(out))
