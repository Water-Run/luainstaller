--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    06_word_counter.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local text = table.concat(arg, " ")
if text == "" then
    text = "Lua keeps small tools pleasant"
end

local count = 0
for _ in text:gmatch("%S+") do
    count = count + 1
end

print("words: " .. count)
