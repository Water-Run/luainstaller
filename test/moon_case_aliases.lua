--[[
Case aliases identify one source without hiding distinct files.

Author:
    WaterRun
File:
    moon_case_aliases.lua
Date:
    2026-10-13
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local hash = require("luainstaller.hash")
local process = require("luainstaller.process")
local moon = require("luainstaller.moon")
local api = require("luainstaller")
local root = assert(fs.makePrivateDirectory("moon-case-aliases"))
local actual = path.join(root, "Main.moon")
local alias = path.join(root, "main.moon")
local included = path.join(root, "Value.moon")
local include_alias = path.join(root, "value.moon")
assert(fs.writeFile(actual, 'name = "value"\nprint "case-alias:" .. (require name)\n'))
assert(fs.writeFile(included, 'return "included-case-alias"\n'))
local read, kind, digest, same_file = fs.readRegularFile, fs.pathType, hash.sha256File, fs.sameFile
local windows = package.config:sub(1, 1) == "\\"
local called, failure = pcall(function()
    if windows or fs.pathType(alias) == "file" then
        local analyzed = api.analyze({entry=alias, include={include_alias}, discovery_mode="manual"})
        assert(analyzed.ok and #analyzed.dependencies.scripts == 1,
            analyzed.error and (analyzed.error.type .. ": " .. analyzed.error.message))
        assert(analyzed.entry == alias)
        local built = api.bundle({entry=alias, include={include_alias}, discovery_mode="manual",
            out=path.join(root, "case-bundle")})
        assert(built.ok, built.error and (built.error.type .. ": " .. built.error.message))
        local ran, output = process.outputCommand(built.executable, {}, {LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("case-alias:included-case-alias", 1, true), output)
        assert(fs.readFile(path.join(built.out, ".luai/build/moon_sources/Value.moon")) == fs.readFile(included),
            "case aliases omitted the original MoonScript material")
        assert(fs.sameFile(actual, alias), "case spelling changed native file identity")
        assert(not fs.sameFile(actual, included), "different sources have the same native file identity")
        local identical = path.join(root, "Other.moon")
        assert(fs.writeFile(identical, assert(fs.readFile(actual))))
        assert(not fs.sameFile(actual, identical), "identical content was mistaken for the same native file")
    else
        local function canonical(value)
            if value == alias then return actual end
            if value == include_alias then return included end
            if value:match("/source/value%.lua$") then return value:gsub("value%.lua$", "Value.lua") end
            return value
        end
        fs.readRegularFile = function(value, ...) return read(canonical(value), ...) end
        fs.pathType = function(value, ...) return kind(canonical(value), ...) end
        hash.sha256File = function(value, ...) return digest(canonical(value), ...) end
        fs.sameFile = function(first, second) return canonical(first) == canonical(second) end
        local config = package.config
        package.config = "\\" .. config:sub(2)
        local modeled = assert(loadfile("src/moon.lua"))()
        package.config = config
        modeled.findCompiler = moon.findCompiler
        local context, error_value = modeled.prepare({entry=alias, include={include_alias}, exclude={},
            max_source_bytes=8388608, max_bundle_bytes=134217728})
        if not context then error(error_value.error.type .. ": " .. error_value.error.message, 0) end
        assert(#context.records == 2, "case aliases compiled a source more than once")
        assert(#context.options.include == 1 and fs.pathType(context.options.include[1]) == "file",
            "a case alias did not map to the prepared include")
        assert(context.options.include[1]:match("/value%.lua$"), "the requested include alias changed its module name")
        assert(context.preparedPath(context.options.include[1]) == context.materials[2].prepared_path,
            "case aliases omitted the canonical relinking material")
        assert(modeled.remap(context.options.include[1], context) == include_alias)
        assert(modeled.remap(context.options.include[1]:gsub("value%.lua$", "VALUE.LUA"), context) == included,
            "case spelling leaked a prepared source path")
        assert(context.cleanup())
        fs.readRegularFile, fs.pathType, hash.sha256File = read, kind, digest
        fs.sameFile = function(first, second) return first == second end
        assert(fs.writeFile(alias, assert(fs.readFile(actual))))
        local distinct, collision = modeled.prepare({entry=actual, include={}, exclude={},
            max_source_bytes=8388608, max_bundle_bytes=134217728})
        if distinct then assert(distinct.cleanup()) end
        assert(not distinct and collision.error.type == "MoonScriptCollisionError",
            "distinct files differing only in case escaped collision checks")
    end
end)
fs.readRegularFile, fs.pathType, hash.sha256File, fs.sameFile = read, kind, digest, same_file
assert(fs.removeTree(root))
assert(called, failure)
print("MoonScript case aliases ok: native case-insensitive filesystem or explicit backend model")
