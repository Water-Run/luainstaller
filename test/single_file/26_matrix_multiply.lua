--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    26_matrix_multiply.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local a = {
    { 1, 2, 3 },
    { 4, 5, 6 },
}

local b = {
    { 7, 8 },
    { 9, 10 },
    { 11, 12 },
}

local result = {}
for i = 1, #a do
    result[i] = {}
    for j = 1, #b[1] do
        local sum = 0
        for k = 1, #b do
            sum = sum + a[i][k] * b[k][j]
        end
        result[i][j] = sum
    end
end

for _, row in ipairs(result) do
    print(table.concat(row, " "))
end
