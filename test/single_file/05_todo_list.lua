--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    05_todo_list.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local items = {
    "read project README",
    "run analyzer",
    "package hello luainstaller",
}

for index, item in ipairs(items) do
    print(string.format("[%d] %s", index, item))
end
