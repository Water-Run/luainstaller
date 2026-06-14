--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    18_stack_parentheses.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local text = arg[1] or "{[()()]}"
local opens = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local closes = { [")"] = true, ["]"] = true, ["}"] = true }
local stack = {}
local ok = true

for ch in text:gmatch(".") do
    if opens[ch] then
        stack[#stack + 1] = opens[ch]
    elseif closes[ch] then
        local expected = table.remove(stack)
        if ch ~= expected then
            ok = false
            break
        end
    end
end

if #stack ~= 0 then
    ok = false
end

print(ok and "balanced" or "not balanced")
