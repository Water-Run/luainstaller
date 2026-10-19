--[[
Publishing a staged executable preserves existing files and refuses links.

Author:
    WaterRun
File:
    publish_noreplace.lua
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
local root = assert(fs.makePrivateDirectory("publish-noreplace"))
local called, failure = pcall(function()
    assert(type(fs.publishFile) == "function", "atomic file publication primitive is missing")
    local source, destination = path.join(root, "staged file"), path.join(root, "published file")
    assert(fs.writeFile(source, "first artifact\0\255"))
    assert(fs.publishFile(source, destination))
    assert(fs.readRegularFile(destination) == "first artifact\0\255")
    local identical = path.join(root, "identical content")
    assert(fs.writeFile(identical, "first artifact\0\255"))
    assert(fs.sameFile(destination, destination) == true)
    assert(fs.sameFile(destination, identical) == false, "content equality replaced file identity")
    if fs.pathType(source) == "file" then assert(fs.removeFile(source)) end
    assert(fs.writeFile(source, "second artifact"))
    assert(not fs.publishFile(source, destination), "publication replaced an existing file")
    assert(fs.readRegularFile(destination) == "first artifact\0\255")
    assert(fs.readRegularFile(source) == "second artifact", "failed publication consumed staging")
    local raced = path.join(root, "raced output")
    if package.config:sub(1, 1) == "/" then
        local original = process.nativeOperation
        process.nativeOperation = function(operation, arguments, ...)
            if operation == "publish_file" then
                assert(fs.writeFile(raced, "user appeared during publication"))
                process.nativeOperation = original
            end
            return original(operation, arguments, ...)
        end
        local published = fs.publishFile(source, raced)
        process.nativeOperation = original
        assert(not published, "publication replaced a file created during the operation")
        assert(fs.readRegularFile(raced) == "user appeared during publication")
        assert(fs.readRegularFile(source) == "second artifact")
    else
        local original = fs.rename
        fs.rename = function(first, second)
            assert(fs.writeFile(raced, "user appeared during publication"))
            fs.rename = original
            return original(first, second)
        end
        local published = fs.publishFile(source, raced)
        fs.rename = original
        assert(not published, "publication replaced a file created during the operation")
        assert(fs.readRegularFile(raced) == "user appeared during publication")
        assert(fs.readRegularFile(source) == "second artifact")
    end
    if package.config:sub(1, 1) == "/" then
        local link, missing = path.join(root, "link"), path.join(root, "missing")
        assert(process.outputCommand("ln", {"-s", destination, link}))
        assert(not fs.publishFile(link, missing), "publication accepted a symlink source")
        assert(fs.pathType(missing) == "missing")
        assert(not fs.publishFile(source, link), "publication replaced a symlink destination")
        assert(fs.readRegularFile(destination) == "first artifact\0\255")
        assert(os.remove(link))
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("atomic no-replace file publication ok")
