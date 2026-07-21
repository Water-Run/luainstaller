--[[
Cross-root artifact reproducibility and runtime-identity tests.

Author:
    WaterRun
File:
    reproducible_artifacts.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("reproducible-artifacts"))
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""

local function cleanup()
    if fs.pathType(root) == "directory" then fs.removeTree(root) end
end

local called, failure = xpcall(function()
    local projects = {}
    for _, parent in ipairs({ "checkout-a", "checkout-b" }) do
        local project = path.join(root, parent, "same-project")
        assert(fs.makeDirectory(project))
        assert(fs.writeFile(path.join(project, "main.lua"), [[
local greeter = require("greeter")
print(greeter.message(arg[1] or "missing"))
print("arg0=" .. tostring(arg[0]))
]]))
        assert(fs.writeFile(path.join(project, "greeter.lua"), [[
return { message = function(value) return "repro " .. value end }
]]))
        projects[#projects + 1] = project
    end

    local onefiles = {}
    local onedirs = {}
    for index, project in ipairs(projects) do
        local onefile = path.join(project, "dist", "app" .. suffix)
        local onedir = path.join(project, "onedir", "app")
        local onefile_result = require("luainstaller").bundle({
            entry = path.join(project, "main.lua"),
            out = onefile,
            mode = "onefile",
        })
        assert(onefile_result.ok, onefile_result.error and table.concat({
            tostring(onefile_result.error.message),
            tostring(onefile_result.error.output or onefile_result.error.cause or ""),
        }, "\n"))
        local onedir_result = require("luainstaller").bundle({
            entry = path.join(project, "main.lua"),
            out = onedir,
            mode = "onedir",
        })
        assert(onedir_result.ok, onedir_result.error and onedir_result.error.message)
        onefiles[index] = onefile_result.executable
        onedirs[index] = onedir_result.executable
    end

    local first_bytes = assert(fs.readRegularFile(onefiles[1]))
    local second_bytes = assert(fs.readRegularFile(onefiles[2]))
    assert(hash.sha256(first_bytes) == hash.sha256(second_bytes),
        "cross-root onefile hashes differ")
    assert(first_bytes == second_bytes, "cross-root onefile bytes differ")

    local username = os.getenv("USER") or os.getenv("USERNAME")
    for index, artifact in ipairs(onefiles) do
        local bytes = assert(fs.readRegularFile(artifact))
        for _, project in ipairs(projects) do
            assert(not bytes:find(project, 1, true),
                "onefile " .. index .. " leaks checkout path " .. project)
        end
        if username and #username >= 3 then
            assert(not bytes:find(username, 1, true),
                "onefile " .. index .. " leaks build username")
        end
    end

    local clean_path = package.config:sub(1, 1) == "\\"
        and "C:\\Windows\\System32;C:\\Windows"
        or "/usr/bin:/bin"
    for _, executable in ipairs({ onedirs[1], onefiles[1], onedirs[2], onefiles[2] }) do
        local ran, output = process.outputCommand(executable, { "identity" }, {
            PATH = clean_path,
            LUA_PATH = "",
            LUA_CPATH = "",
            LUA_INIT = "",
            LUA_INIT_5_1 = "",
            LUA_INIT_5_2 = "",
            LUA_INIT_5_3 = "",
            LUA_INIT_5_4 = "",
            LUA_INIT_5_5 = "",
        })
        assert(ran, output)
        assert(output:find("repro identity", 1, true), output)
        local reported = assert(output:match("arg0=([^\r\n]+)"), output)
        assert(path.normalize(reported) == path.normalize(executable),
            "arg[0] mismatch: expected " .. executable .. ", got " .. reported)
    end
end, function(err)
    return err
end)

cleanup()
assert(called, failure)
print("reproducible artifacts ok: cross-root bytes, no paths, executable arg[0]")
