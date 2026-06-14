--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    10_prime_numbers.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local limit = tonumber(arg[1]) or 50
local primes = {}

for n = 2, limit do
    local is_prime = true
    for d = 2, math.floor(math.sqrt(n)) do
        if n % d == 0 then
            is_prime = false
            break
        end
    end
    if is_prime then
        primes[#primes + 1] = n
    end
end

print(table.concat(primes, ", "))
