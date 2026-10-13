--[[
MoonScript failures stay structured and release their private workspace.

Author:
    WaterRun
File:
    moon_failure_cleanup.lua
Date:
    2026-10-13
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local moon = require("luainstaller.moon")
local root = assert(fs.makePrivateDirectory("moon-failure-test"))
local entry = path.join(root, "main.moon")
assert(fs.writeFile(entry, 'print "moon-failure-fixture"\n'))
local prepare, remap = moon.prepare, moon.remap
local called, failure = pcall(function()
    for _, fault in ipairs({"prepare", "verify", "remap", "cleanup"}) do
        local context
        moon.prepare = function(opts)
            if fault == "prepare" then error("injected compiler lookup failure", 0) end
            local prepared, error_value = prepare(opts)
            context = prepared
            if prepared and fault == "verify" then
                prepared.verify = function() error("injected source verification failure", 0) end
            elseif prepared and fault == "cleanup" then
                prepared.cleanup = function() error("injected workspace cleanup failure", 0) end
            end
            return prepared, error_value
        end
        moon.remap = fault == "remap" and function() error("injected path mapping failure", 0) end or remap
        local returned, response = pcall(api.analyze, {entry=entry})
        moon.prepare, moon.remap = prepare, remap
        local workspace_left = context and fs.pathType(context.workspace) ~= "missing"
        if workspace_left then assert(fs.removeTree(context.workspace)) end
        assert(returned, fault .. " escaped the public result boundary: " .. tostring(response))
        assert(not response.ok and type(response.error) == "table", fault .. " did not return a structured error")
        if fault == "cleanup" then
            assert(response.error.type == "FilesystemError" and response.error.cleanup_path == context.workspace)
        else
            assert(not workspace_left, fault .. " leaked its private workspace")
        end
    end
    local context
    moon.prepare = function(opts)
        local prepared, error_value = prepare(opts)
        context = prepared
        if prepared then prepared.cleanup = function() error("injected cleanup after publication", 0) end end
        return prepared, error_value
    end
    local returned, response = pcall(api.bundle, {entry=entry, out=path.join(root, "app")})
    moon.prepare = prepare
    if context and fs.pathType(context.workspace) ~= "missing" then assert(fs.removeTree(context.workspace)) end
    assert(returned and not response.ok and response.error.type == "FilesystemError")
    assert(response.error.committed == true, "cleanup failure hid a committed bundle")
    assert(fs.pathType(path.join(root, "app")) == "directory", "cleanup failure removed the committed bundle")
end)
moon.prepare, moon.remap = prepare, remap
assert(fs.removeTree(root))
assert(called, failure)
print("MoonScript failure cleanup ok")
