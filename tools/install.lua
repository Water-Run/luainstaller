#!/usr/bin/env lua
--[[
Offline standalone installation, using only Lua and the host filesystem tools.

Author:
    WaterRun
File:
    install.lua
Date:
    2026-09-22
Updated:
    2026-09-22
]]

local function fail(message)
    io.stderr:write("install: ", tostring(message), "\n")
    os.exit(1)
end

local options = {}
local index = 1
while index <= #arg do
    local key = arg[index]
    if key == "--help" or key == "-h" then
        print("Usage: lua tools/install.lua --prefix <new-directory> [--lua <interpreter>]")
        print("Installs offline into a new, dedicated directory. Existing paths are refused.")
        os.exit(0)
    end
    if key ~= "--prefix" and key ~= "--lua" then fail("unknown option: " .. key) end
    if options[key] then fail("duplicate option: " .. key) end
    local value = arg[index + 1]
    if not value or value == "" or value:match("^%-%-") or value:find("%c") then
        fail(key .. " requires a non-empty path without control characters")
    end
    options[key] = value
    index = index + 2
end
if not options["--prefix"] then fail("--prefix is required (use --help)") end
if rawget(_G, "jit") or not _VERSION:match("^Lua 5%.[1-5]$") then
    fail("official Lua 5.1 through 5.5 is required")
end

local directory = arg[0]:match("^(.*[/\\])") or "./"
local api = dofile(directory .. "../luainstaller.lua")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local windows = package.config:sub(1, 1) == "\\"
local source_root = path.absolute(directory .. "..")
local prefix = options["--prefix"]
if path.isDriveRelative(prefix) then fail("--prefix must not be drive-relative") end
prefix = path.absolute(prefix)

-- Only publish under an existing, non-symlink parent. The filesystem helper
-- verifies ownership of macOS's root-owned /tmp and /var directory aliases.
local parent = path.dirname(prefix)
local current = parent
while true do
    local kind = fs.pathType(current)
    local system_alias = not windows and (current == "/tmp" or current == "/var")
        and kind == "reparse" and fs.makeDirectory(current)
    if kind ~= "directory" and not system_alias then
        fail("parent must exist and have no symlink ancestors: " .. current)
    end
    local next_parent = path.dirname(current)
    if next_parent == current then break end
    current = next_parent
end
if fs.pathType(prefix) ~= "missing" then fail("destination already exists: " .. prefix) end

local current_lua = "lua"
local argument_index = -1
while arg[argument_index] do
    current_lua = arg[argument_index]
    argument_index = argument_index - 1
end
local lua = options["--lua"] or current_lua
if lua:find('[%c"]') or path.isDriveRelative(lua) then fail("invalid interpreter path") end
if lua:find("[/\\]") then lua = path.absolute(lua) end
local checked, banner = process.outputCommand(lua, {
    "-e", "assert(not jit); io.write(_VERSION)",
})
if not checked or banner ~= _VERSION then
    fail("--lua must run the same official Lua ABI as the installer: " .. tostring(banner))
end

local stage, stage_error = fs.makePrivateDirectory("install", parent)
if not stage then fail(stage_error) end
local function install()
    local function copy(relative)
        local destination = path.join(stage, relative)
        assert(fs.makeDirectory(path.dirname(destination)))
        assert(fs.copyFile(path.join(source_root, relative), destination))
    end
    for _, entry in ipairs(assert(fs.listTree(path.join(source_root, "src")))) do
        if entry.path:match("^[%w_]+%.lua$") then
            assert(entry.type == "file", "source module must be a regular file: " .. entry.path)
            copy("src/" .. entry.path)
        end
    end
    for _, relative in ipairs({
        "luainstaller.lua", "bin/luai.lua", "bin/luainstaller.lua",
        "LICENSE", "LICENSES/GPL-3.0-or-later.txt", "LICENSES/Lua-MIT.txt",
        "THIRD_PARTY_NOTICES.md", "README.adoc", "CHANGELOG.adoc", "luainstaller.1",
    }) do copy(relative) end
    for _, entry in ipairs(assert(fs.listTree(path.join(source_root, "docs")))) do
        if entry.type == "file" and entry.path:match("%.adoc$") then copy("docs/" .. entry.path) end
    end
    for _, name in ipairs({ "luai", "luainstaller" }) do
        local launcher = path.join(stage, "bin/" .. name)
        if windows then
            local quoted_lua = lua:gsub("/", "\\"):gsub("%%", "%%%%")
            assert(fs.writeFile(launcher .. ".cmd", table.concat({
                "@echo off", "setlocal DisableDelayedExpansion",
                'if not defined LUAI_LUA set "LUAI_LUA=' .. quoted_lua .. '"',
                '"%LUAI_LUA%" "%~dp0' .. name .. '.lua" %*',
                "exit /b %errorlevel%", "",
            }, "\r\n")))
        else
            assert(fs.writeFile(launcher, table.concat({
                "#!/bin/sh", "set -eu",
                'directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
                'lua=${LUAI_LUA:-}',
                'if [ -z "$lua" ]; then lua=' .. process.shellQuote(lua) .. '; fi',
                'exec "$lua" "$directory/' .. name .. '.lua" "$@"', "",
            }, "\n")))
            assert(fs.setExecutable(launcher))
        end
    end
    assert(fs.writeFile(path.join(stage, "INSTALLATION.txt"),
        "luainstaller " .. api.VERSION .. "\nLua ABI: " .. _VERSION
        .. "\nDedicated standalone tree; remove this directory to uninstall.\n"))
    -- Smoke the staged modules before making the destination visible.
    local ok, output = process.outputCommand(lua, { path.join(stage, "bin/luai.lua"), "-v" }, {
        LUA_PATH = "", LUA_CPATH = "",
    })
    assert(ok and output == "luai " .. api.VERSION .. "\n", output)
    assert(fs.rename(stage, prefix))
end

local ok, err = pcall(install)
if not ok then
    local cleaned, cleanup_error = fs.removeTree(stage)
    if not cleaned then io.stderr:write("staging cleanup failed: ", tostring(cleanup_error), "\n") end
    fail(err)
end
print("Installed luainstaller " .. api.VERSION .. " into " .. prefix)
print("Add to PATH: " .. path.join(prefix, "bin"))
print("Library: add " .. path.join(prefix, "?.lua") .. " to package.path")
