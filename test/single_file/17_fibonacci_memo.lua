--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    17_fibonacci_memo.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local n = tonumber(arg[1]) or 12
local memo = { [0] = 0, [1] = 1 }

local function fib(value)
    if memo[value] ~= nil then
        return memo[value]
    end
    memo[value] = fib(value - 1) + fib(value - 2)
    return memo[value]
end

print(string.format("fib(%d) = %d", n, fib(n)))
