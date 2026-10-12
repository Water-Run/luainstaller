--[[
Output paths refuse unsafe ancestors and preserve unrelated files.

Author:
    WaterRun
File:
    output_parents.lua
Date:
    2026-10-12
Updated:
    2026-10-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local api = require("luainstaller")
local root = assert(fs.makePrivateDirectory("output-parents"))
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, "print('safe-parent')\n"))
    local target, link = path.join(root, "target"), path.join(root, "link")
    assert(fs.makeDirectory(target))
    local sentinel = path.join(target, "USER.txt")
    assert(fs.writeFile(sentinel, "preserve me\n"))
    if package.config:sub(1, 1) == "\\" then
        local fixture = dofile("test/support/windows_fixture.lua")(root)
        local linked, output = process.outputCommand(fixture, {"junction", link, target})
        assert(linked, output)
    else
        assert(process.outputCommand("ln", {"-s", target, link}))
    end
    for _, mode in ipairs({"onedir", "onefile"}) do
        local rejected = api.bundle({entry=entry, out=path.join(link, "app-" .. mode), mode=mode})
        assert(not rejected.ok and rejected.error.type == "InvalidOutputError",
            "linked output ancestor was accepted: " .. mode)
        assert(fs.readRegularFile(sentinel) == "preserve me\n")
        assert(fs.pathType(path.join(target, "app-" .. mode)) == "missing")
    end
    if package.config:sub(1, 1) == "\\" then
        assert(fs.removeFile(link))
    else
        assert(os.remove(link))
        assert(process.outputCommand("chmod", {"0777", target}))
        local rejected = api.bundle({entry=entry, out=path.join(target, "app")})
        assert(not rejected.ok and rejected.error.type == "InvalidOutputError",
            "shared writable output ancestor was accepted")
        assert(process.outputCommand("chmod", {"0700", target}))
    end
    local built = api.bundle({entry=entry, out=path.join(target, "app")})
    assert(built.ok, built.error and built.error.message)
end)
local link = path.join(root, "link")
if fs.pathType(link) == "reparse" then
    if package.config:sub(1, 1) == "\\" then assert(fs.removeFile(link))
    else assert(os.remove(link)) end
end
assert(fs.removeTree(root))
assert(called, failure)
print("output parent safety ok")
