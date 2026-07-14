--[[
Isolated LuaRocks installation and installed-command integration test.

Author:
    WaterRun
File:
    luarocks_install.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

assert(fs.pathType("tools/install-source.sh") == "missing",
    "LuaRocks must be the only supported installation path")

local available = process.outputCommand("luarocks", { "--version" })
if not available then
    print("isolated LuaRocks install skipped: luarocks unavailable")
    return
end

local root = assert(fs.makePrivateDirectory("luarocks-install"))
local tree = path.join(root, "tree")
local project = path.join(root, "outside-checkout")
local out = path.join(root, "bundle")
assert(fs.makeDirectory(project))
assert(fs.writeFile(path.join(project, "greeting.lua"), [[
return { message = function(value) return "installed " .. value end }
]]))
assert(fs.writeFile(path.join(project, "main.lua"), [[
print(require("greeting").message(arg[1] or "missing"))
]]))

local installed, install_output = process.outputCommand("luarocks", {
    "make",
    "--tree", tree,
    path.absolute("luainstaller-1.0.0-1.rockspec"),
})
assert(installed, install_output)

local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
local bin = path.join(tree, "bin")
local luai = path.join(bin, "luai" .. suffix)
local full = path.join(bin, "luainstaller" .. suffix)
assert(fs.pathType(luai) == "file", "LuaRocks did not install luai")
assert(fs.pathType(full) == "file", "LuaRocks did not install luainstaller")

local version_ok, version_output = process.outputCommand(luai, { "-v" })
assert(version_ok and version_output == "luai 1.0.0\n", version_output)
local built, build_output = process.outputCommand(full, {
    "build", "--dir", path.join(project, "main.lua"),
    "-o", out, "--max-deps", "20",
})
assert(built, build_output)

local executable = path.join(out, path.basename(out) .. suffix)
local ran, run_output = process.outputCommand(executable, { "outside" }, {
    PATH = package.config:sub(1, 1) == "\\"
        and "C:\\Windows\\System32;C:\\Windows"
        or "/usr/bin:/bin",
    LUA_PATH = "",
    LUA_CPATH = "",
})
assert(ran and run_output:find("installed outside", 1, true), run_output)
assert(fs.removeTree(root))

print("isolated LuaRocks install and clean-target bundle ok")
