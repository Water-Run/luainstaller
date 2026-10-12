--[[
Unexpected interruptions unwind owned runtime and onefile workspaces.

Author:
    WaterRun
File:
    build_cleanup.lua
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
local root = assert(fs.makePrivateDirectory("build-cleanup"))
local entry = path.join(root, "main.lua")
assert(fs.writeFile(entry, "print('cleanup-check')\n"))
local original_private, original_output, original_chunks = fs.makePrivateDirectory,
    process.outputCommand, fs.writeChunks
local owned = {}
fs.makePrivateDirectory = function(label, parent)
    local directory, err = original_private(label, parent)
    if directory and (label == "require-trace" or label == "onefile-work" or label == "luai-output") then
        owned[#owned + 1] = directory
    end
    return directory, err
end
local checked, failure = pcall(function()
    process.outputCommand = function(executable, arguments, environment, options)
        if arguments and arguments[1] and arguments[1]:match("/trace%.lua$") then
            error({type="InterruptedError", message="injected runtime interruption"}, 0)
        end
        return original_output(executable, arguments, environment, options)
    end
    local called, traced = pcall(api.analyze, {entry=entry, discovery_mode="runtime", lua=harness.lua_command()})
    process.outputCommand = original_output
    assert(called and not traced.ok and traced.error.type == "InterruptedError",
        "runtime interruption escaped the public result boundary")
    for _, directory in ipairs(owned) do
        assert(fs.pathType(directory) == "missing", "interrupted trace left its workspace: " .. directory)
    end
    fs.writeChunks = function(file, producer, limit)
        if file:match("/payload%.inc$") then
            error({type="InterruptedError", message="injected payload interruption"}, 0)
        end
        return original_chunks(file, producer, limit)
    end
    local out = path.join(root, "app")
    local bundled, built = pcall(api.bundle, {entry=entry, out=out, mode="onefile"})
    fs.writeChunks = original_chunks
    assert(bundled and not built.ok and built.error.type == "InterruptedError",
        "onefile interruption escaped the public result boundary")
    assert(fs.pathType(out) == "missing", "interrupted build published an output")
    for _, directory in ipairs(owned) do
        assert(fs.pathType(directory) == "missing", "interrupted build left its workspace: " .. directory)
    end
end)
fs.makePrivateDirectory, process.outputCommand, fs.writeChunks = original_private, original_output, original_chunks
for _, directory in ipairs(owned) do
    if fs.pathType(directory) == "directory" then assert(fs.removeTree(directory)) end
end
assert(fs.removeTree(root))
assert(checked, failure)
print("protected build cleanup ok")
