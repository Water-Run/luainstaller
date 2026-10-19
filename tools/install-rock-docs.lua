#!/usr/bin/env lua
--[[
Install canonical user documents into a LuaRocks package directory.

Author:
    WaterRun
File:
    install-rock-docs.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local source = (arg[0]:match("^(.*[/\\])") or "./") .. "../"
local process = assert(loadfile(source .. "src/process.lua"))()
package.loaded["luainstaller.process"] = process
local path = assert(loadfile(source .. "src/path.lua"))()
local destination = assert(arg[1], "LuaRocks package directory is required")
assert(arg[2] == nil, "unexpected installer argument")
assert(path.isAbsolute(destination), "LuaRocks package directory must be absolute")

local documents = {
    "LICENSE", "README.adoc", "README.zh-CN.adoc", "THIRD_PARTY_NOTICES.md",
    "CHANGELOG.adoc", "luainstaller.1",
}
local contents = {}
for _, name in ipairs(documents) do
    local handle = assert(io.open(path.join(source, name), "rb"))
    contents[name] = assert(handle:read("*a"))
    assert(handle:close())
end
for _, name in ipairs(documents) do
    local handle = assert(io.open(path.join(destination, name), "wb"))
    local wrote, write_error = handle:write(contents[name])
    local closed, close_error = handle:close()
    assert(wrote and closed, write_error or close_error)
end
print("Installed user documentation and notices")
