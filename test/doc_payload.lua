--[[
Byte identity of the LuaRocks doc/ install copies.

Author:
    WaterRun
File:
    doc_payload.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")

local copies = {
    ["doc/LICENSE"] = "LICENSE",
    ["doc/README.adoc"] = "README.adoc",
    ["doc/README.zh-CN.adoc"] = "README.zh-CN.adoc",
    ["doc/THIRD_PARTY_NOTICES.md"] = "THIRD_PARTY_NOTICES.md",
    ["doc/CHANGELOG.adoc"] = "CHANGELOG.adoc",
    ["doc/luainstaller.1"] = "luainstaller.1",
}
for installed, source in pairs(copies) do
    local left = fs.readRegularFile(installed)
    local right = fs.readRegularFile(source)
    assert(left == right, installed .. " differs from " .. source)
end
local rockspec = fs.readRegularFile("luainstaller-" .. require("luainstaller").VERSION .. "-1.rockspec")
assert(rockspec:find('copy_directories = { "doc", "docs", "LICENSES" }', 1, true),
    "rockspec does not copy the license and documentation directories")
print("doc payload copies match")
