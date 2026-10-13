--[[
Static-Lua capability validation rejects malformed or hidden PE imports.

Author:
    WaterRun
File:
    static_windows_image.lua
Date:
    2026-10-13
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local toolchain = require("luainstaller.toolchain")
local root = assert(fs.makePrivateDirectory("static-pe"))
local filename = path.join(root, "probe.exe")
local function little(value, size)
    local bytes = {}
    for _ = 1, size do bytes[#bytes + 1] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function image(optional_size, directory_count)
    local bytes = string.rep("\0", 512)
    local function replace(position, value)
        bytes = bytes:sub(1, position - 1) .. value .. bytes:sub(position + #value)
    end
    replace(1, "MZ"); replace(61, little(64, 4)); replace(65, "PE\0\0")
    replace(71, little(0, 2)); replace(85, little(optional_size, 2))
    replace(89, little(267, 2)); replace(149, little(512, 4))
    replace(181, little(directory_count, 4))
    return bytes, replace
end
local called, failure = pcall(function()
    assert(fs.writeFile(filename, image(224, 16)))
    assert(toolchain.verifyStaticWindowsImage(filename))
    assert(fs.writeFile(filename, image(96, 16)))
    local accepted = toolchain.verifyStaticWindowsImage(filename)
    assert(not accepted, "import-directory bytes beyond the optional header were trusted")
    assert(fs.writeFile(filename, image(224, 32)))
    assert(not toolchain.verifyStaticWindowsImage(filename), "out-of-bounds directory count was accepted")
end)
assert(fs.removeTree(root))
assert(called, failure)
print("static Windows image validation ok")
