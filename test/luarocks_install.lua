--[[
Isolated LuaRocks installation and installed-command integration test.

Author:
    WaterRun
File:
    luarocks_install.lua
Date:
    2026-07-14
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local available = process.outputCommand("luarocks", { "--version" })
assert(available, "LuaRocks is required for the installation contract")

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
    path.absolute("luainstaller-1.8.2-1.rockspec"),
})
assert(installed, install_output)

local windows = package.config:sub(1, 1) == "\\"
local driver_timeout = (_VERSION == "Lua 5.1" or _VERSION == "Lua 5.2") and 600 or 120
local command_suffix = windows and ".bat" or ""
local bin = path.join(tree, "bin")
local luai = path.join(bin, "luai" .. command_suffix)
local full = path.join(bin, "luainstaller" .. command_suffix)
assert(fs.pathType(luai) == "file", "LuaRocks did not install luai")
assert(fs.pathType(full) == "file", "LuaRocks did not install luainstaller")
local lua_abi = assert(_VERSION:match("Lua (%d+%.%d+)"))
assert(fs.pathType(path.join(
    tree, "share/lua/" .. lua_abi .. "/luainstaller/distribution_files.lua"
)) == "file", "LuaRocks did not install distribution materials")
local rock_root = path.join(tree, "lib/luarocks/rocks-" .. lua_abi
    .. "/luainstaller/" .. require("luainstaller").VERSION .. "-1")
local function sameFile(relative, source)
    local installed = fs.readRegularFile(path.join(rock_root, relative))
    local original = fs.readRegularFile(source)
    assert(installed == original, "LuaRocks install mismatch: " .. relative)
end
sameFile("LICENSES/GPL-3.0-or-later.txt", "LICENSES/GPL-3.0-or-later.txt")
sameFile("LICENSES/Lua-MIT.txt", "LICENSES/Lua-MIT.txt")
sameFile("LICENSES/LuaJIT-MIT.txt", "LICENSES/LuaJIT-MIT.txt")
sameFile("LICENSE", "LICENSE")
sameFile("README.adoc", "README.adoc")
sameFile("README.zh-CN.adoc", "README.zh-CN.adoc")
sameFile("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md")
sameFile("CHANGELOG.adoc", "CHANGELOG.adoc")
sameFile("luainstaller.1", "luainstaller.1")
sameFile("docs/RELINKING.adoc", "docs/RELINKING.adoc")
local function checkLinks(relative)
    local text = assert(fs.readRegularFile(path.join(rock_root, relative)))
    for target in text:gmatch("xref:([^%[#]+)") do
        local resolved = path.normalize(path.join(path.dirname(relative), target))
        assert(fs.pathType(path.join(rock_root, resolved)) == "file",
            "installed documentation link is missing: " .. relative .. " -> " .. target)
    end
end
checkLinks("README.adoc")
checkLinks("README.zh-CN.adoc")
for _, item in ipairs(assert(fs.listTree("docs"))) do
    if item.type == "file" and item.path:match("%.adoc$") then
        sameFile("docs/" .. item.path, "docs/" .. item.path)
        checkLinks("docs/" .. item.path)
    end
end
assert(fs.pathType(path.join(rock_root, "AGENTS.md")) == "missing", "AGENTS.md was installed")
assert(fs.pathType(path.join(rock_root, "doc/AGENTS.md")) == "missing", "doc/AGENTS.md was installed")

local function installedCommand(command, arguments, environment)
    if not windows then
        return process.outputCommand(command, arguments, environment, {timeout_seconds=driver_timeout})
    end
    local command_line = { process.quote(command) }
    for _, value in ipairs(arguments or {}) do
        command_line[#command_line + 1] = process.quote(value)
    end
    local comspec = assert(os.getenv("ComSpec") or os.getenv("COMSPEC"))
    return process.outputCommand(comspec, {
        "/d", "/s", "/c", table.concat(command_line, " "),
    }, environment, {timeout_seconds=driver_timeout})
end

local version_ok, version_output = installedCommand(luai, { "-v" })
assert(version_ok and version_output == "luai 1.8.2\n", version_output)
local runtime_ok, runtime_output = installedCommand(luai, {
    "-a", path.join(project, "main.lua"),
    "--discovery-mode", "runtime",
    "--", "runtime",
})
assert(runtime_ok, runtime_output)
assert(runtime_output:find("scripts: 1", 1, true), runtime_output)
assert(runtime_output:find(path.join(project, "greeting.lua"), 1, true), runtime_output)
local built, build_output = installedCommand(full, {
    "build", "--dir", path.join(project, "main.lua"),
    "-o", out, "--max-deps", "20", "--verbose",
})
assert(built, build_output)
assert(harness.read_file(path.join(out, ".luai/licenses/Lua-MIT.txt"))
    == harness.read_file("LICENSES/Lua-MIT.txt"))
assert(harness.read_file(path.join(out, ".luai/licenses/LGPL-3.0-or-later.txt"))
    == harness.read_file("LICENSE"))
assert(harness.read_file(path.join(out, ".luai/licenses/GPL-3.0-or-later.txt"))
    == harness.read_file("LICENSES/GPL-3.0-or-later.txt"))
assert(harness.read_file(path.join(out, "THIRD_PARTY_NOTICES.md"))
    == harness.read_file("THIRD_PARTY_NOTICES.md"))

local executable = path.join(out, path.basename(out) .. (windows and ".exe" or ""))
local empty_path = path.join(root, "empty-path")
assert(fs.makeDirectory(empty_path))
local ran, run_output = process.outputCommand(executable, { "outside" }, {
    PATH = empty_path,
    LUA_PATH = "",
    LUA_CPATH = "",
})
assert(ran and run_output:find("installed outside", 1, true), run_output)
assert(fs.removeTree(root))

print("isolated LuaRocks install and clean-target bundle ok")
