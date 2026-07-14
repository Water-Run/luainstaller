--[[
Native compiler and Lua development metadata integration test.

Author:
    WaterRun
File:
    toolchain_native.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local toolchain = require("luainstaller.toolchain")

local working_probe_object = path.normalize("probe.obj")
if fs.pathType(working_probe_object) == "file" then
    assert(fs.removeFile(working_probe_object))
end

local config, config_err = toolchain.resolve({ lua_version = compat.luaVersion() })
local diagnostic = {}
if config_err and config_err.error then
    diagnostic[#diagnostic + 1] = config_err.error.message or "toolchain error"
    diagnostic[#diagnostic + 1] = tostring(config_err.error.cause or "")
    for _, failure in ipairs(config_err.error.failures or {}) do
        diagnostic[#diagnostic + 1] = table.concat({
            tostring(failure.message or "candidate failed"),
            tostring(failure.output or failure.cause or ""),
        }, ": ")
    end
end
assert(config, table.concat(diagnostic, "\n"))
assert(type(config.cc) == "string" and config.cc ~= "")
assert(type(config.include_dir) == "string" and config.include_dir ~= "")
assert(config.lua_version.abi == compat.luaVersion().abi)
assert(config.link_mode == "static"
    or (config.link_mode == "shared" and type(config.runtime_path) == "string"))
assert(fs.pathType(working_probe_object) == "missing",
    "MSVC toolchain probe leaked probe.obj into the working directory")

print(table.concat({
    "native toolchain ok:",
    config.compiler_family,
    config.lua_version.abi,
    config.link_mode,
}, " "))
