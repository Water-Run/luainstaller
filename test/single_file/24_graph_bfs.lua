--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    24_graph_bfs.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local graph = {
    A = { "B", "C" },
    B = { "D", "E" },
    C = { "F" },
    D = {},
    E = { "F" },
    F = {},
}

local queue = { "A" }
local head = 1
local seen = { A = true }
local order = {}

while head <= #queue do
    local node = queue[head]
    head = head + 1
    order[#order + 1] = node
    for _, next_node in ipairs(graph[node]) do
        if not seen[next_node] then
            seen[next_node] = true
            queue[#queue + 1] = next_node
        end
    end
end

print(table.concat(order, " -> "))
