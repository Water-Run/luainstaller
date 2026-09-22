--[[
Load the public API directly from a source or standalone installation tree.

Author:
    WaterRun
File:
    luainstaller.lua
Date:
    2026-09-22
Updated:
    2026-09-22
]]

local source = debug.getinfo(1, "S").source
assert(source:sub(1, 1) == "@", "luainstaller must be loaded from a file")
local root = (source:sub(2):match("^(.*[/\\])") or "./") .. "src/"
local searchers = package.searchers or package.loaders

-- Restrict this loader to our namespace; application dependency paths stay intact.
table.insert(searchers, 1, function(name)
    local leaf = name:match("^luainstaller%.([%w_]+)$")
    if not leaf then return "\n\tnot a luainstaller source module" end
    local chunk, err = loadfile(root .. leaf .. ".lua")
    if not chunk then error(err, 0) end
    return chunk
end)

-- Freeze the checkout location before a caller changes its working directory.
root = require("luainstaller.path").absolute(root) .. "/"
return assert(loadfile(root .. "init.lua"))()
