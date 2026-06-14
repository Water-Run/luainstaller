--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    23_binary_tree_traversal.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local tree = {
    value = 8,
    left = {
        value = 3,
        left = { value = 1 },
        right = { value = 6 },
    },
    right = {
        value = 10,
        right = { value = 14 },
    },
}

local out = {}

local function inorder(node)
    if not node then
        return
    end
    inorder(node.left)
    out[#out + 1] = node.value
    inorder(node.right)
end

inorder(tree)
print(table.concat(out, ", "))
