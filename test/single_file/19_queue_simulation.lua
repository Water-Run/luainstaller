--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    19_queue_simulation.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local queue = { first = 1, last = 0 }

local function push(value)
    queue.last = queue.last + 1
    queue[queue.last] = value
end

local function pop()
    if queue.first > queue.last then
        return nil
    end
    local value = queue[queue.first]
    queue[queue.first] = nil
    queue.first = queue.first + 1
    return value
end

push("Alice")
push("Bob")
push("Carol")

print("served: " .. pop())
push("Dave")
print("served: " .. pop())
print("served: " .. pop())
print("served: " .. pop())
