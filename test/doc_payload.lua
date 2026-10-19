--[[
Canonical documentation installation without checked-in copies.

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
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("documentation-payload"))
local called, failure = pcall(function()
    local installed, diagnostic = process.outputCommand(harness.lua_command(), {
        "tools/install-rock-docs.lua", path.absolute(root),
    })
    assert(installed, diagnostic)
    for _, name in ipairs({"LICENSE", "README.adoc", "README.zh-CN.adoc",
        "THIRD_PARTY_NOTICES.md", "CHANGELOG.adoc", "luainstaller.1"}) do
        local copy = fs.readRegularFile(path.join(root, name))
        assert(copy == assert(fs.readRegularFile(name)), "installed document differs: " .. name)
    end
    assert(fs.pathType(path.join(root, "AGENTS.md")) == "missing")
    assert(fs.pathType(path.join(root, "dev")) == "missing")
end)
assert(fs.removeTree(root))
assert(called, failure)
print("canonical documentation payload installed")
