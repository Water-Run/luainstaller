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
local function imported_image(is_64, dll, descriptor_count)
    local bytes = string.rep("\0", 65536)
    local function replace(position, value)
        bytes = bytes:sub(1, position - 1) .. value .. bytes:sub(position + #value)
    end
    local optional_size = is_64 and 240 or 224
    local directories = is_64 and 201 or 185
    local section = 89 + optional_size
    replace(1, "MZ"); replace(61, little(64, 4)); replace(65, "PE\0\0")
    replace(71, little(1, 2)); replace(85, little(optional_size, 2))
    replace(89, little(is_64 and 523 or 267, 2)); replace(149, little(512, 4))
    replace(directories - 4, little(16, 4))
    replace(section + 12, little(4096, 4))
    replace(section + 16, little(#bytes - 512, 4)); replace(section + 20, little(512, 4))
    descriptor_count = descriptor_count or 1
    replace(directories + 8, little(4096, 4))
    replace(directories + 12, little((descriptor_count + 1) * 20, 4))
    for index = 0, descriptor_count - 1 do
        replace(513 + index * 20 + 12, little(4096 + 60000, 4))
    end
    replace(513 + 60000, dll .. "\0")
    return function() return bytes end, replace, directories, section
end
local function check_image(content, expected, message)
    assert(fs.writeFile(filename, content))
    local accepted = toolchain.verifyStaticWindowsImage(filename)
    assert((accepted == true) == expected, message)
end
local called, failure = pcall(function()
    assert(fs.writeFile(filename, image(224, 16)))
    assert(toolchain.verifyStaticWindowsImage(filename))
    assert(fs.writeFile(filename, image(96, 16)))
    local accepted = toolchain.verifyStaticWindowsImage(filename)
    assert(not accepted, "import-directory bytes beyond the optional header were trusted")
    assert(fs.writeFile(filename, image(224, 32)))
    assert(not toolchain.verifyStaticWindowsImage(filename), "out-of-bounds directory count was accepted")
    for _, is_64 in ipairs({false, true}) do
        for _, dll in ipairs({"KERNEL32.DLL", "ucrtbase.dll", "api-ms-win-core-file-l1-1-0.dll",
            "ext-ms-win-ntuser-window-l1-1-0.dll"}) do
            local contents = imported_image(is_64, dll)
            check_image(contents(), true, "a system import was rejected: " .. dll)
        end
        for _, dll in ipairs({"lua54.dll", "vcruntime140.dll", "../kernel32.dll", "",
            "api-ms-win-" .. string.rep("x", 260) .. ".dll"}) do
            local contents = imported_image(is_64, dll)
            check_image(contents(), false, "an external or malformed DLL was accepted: " .. dll)
        end
        local contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(directories + 13 * 8, little(4096, 4))
        replace(directories + 13 * 8 + 4, little(32, 4))
        check_image(contents(), false, "delayed imports were accepted")
        contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(directories + 12, little(20, 4))
        check_image(contents(), false, "a descriptor without a terminator was accepted")
        contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(525, little(0xffffffff, 4))
        check_image(contents(), false, "an unmapped DLL name RVA was accepted")
        contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(directories + 12, little(65536, 4))
        check_image(contents(), false, "imports extending outside a section were accepted")
        contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(section + 16, little(65536, 4))
        check_image(contents(), false, "a raw section outside the file was accepted")
        contents, replace, directories, section = imported_image(is_64, "kernel32.dll")
        replace(section + 20, little(128, 4))
        check_image(contents(), false, "a raw section overlapping the headers was accepted")
        contents = imported_image(is_64, "kernel32.dll", 2047)
        check_image(contents(), true, "a terminated import table at the descriptor budget was rejected")
        contents = imported_image(is_64, "kernel32.dll", 2048)
        check_image(contents(), false, "the import descriptor budget was ignored")
    end
    for _, content in ipairs({"", "MZ", "PE\0\0", image(224, 16):sub(1, 80)}) do
        check_image(content, false, "truncated PE headers were accepted")
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("static Windows image validation ok")
