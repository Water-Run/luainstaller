--[[
Production hardening regression suite for luainstaller.

Author:
    WaterRun
File:
    production_edges.lua
Date:
    2026-07-11
Updated:
    2026-07-11
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fileExists = harness.file_exists
local makeDirectory = harness.mkdir
local makeTempDir = harness.make_temp_dir
local removeTree = harness.remove_tree
local readFile = harness.read_file
local writeFile = harness.write_file
local shellQuote = harness.shell_quote
local commandOutputTrimmed = harness.command_output_trimmed
local runCommand = harness.run

local tests = {}

local function test(name, fn)
    tests[#tests + 1] = {
        name = name,
        fn = fn,
    }
end

local function assertEqual(actual, expected, label)
    assert(actual == expected, string.format(
        "%s: expected %q, got %q",
        tostring(label or "value"),
        tostring(expected),
        tostring(actual)
    ))
end

local function fnv1a32Collision(content)
    assert(#content >= 5, "collision fixture must be at least five bytes")
    local mask = 0xffffffff
    local prime = 16777619
    local inverse = 899433627
    local function step(state, byte)
        return ((state ~ byte) * prime) & mask
    end
    local state = 2166136261
    local prefix = content:sub(1, -6)
    for index = 1, #prefix do
        state = step(state, prefix:byte(index))
    end
    local forward = {}
    for first = 0, 255 do
        local once = step(state, first)
        for second = 0, 255 do
            local twice = step(once, second)
            if forward[twice] == nil then
                forward[twice] = string.char(first, second)
            end
        end
    end

    local target = tonumber(require("luainstaller.hash").fnv1a32(content), 16)
    local original_suffix = content:sub(-5)
    for fifth = 0, 255 do
        local before_fifth = ((target * inverse) & mask) ~ fifth
        for fourth = 0, 255 do
            local before_fourth = ((before_fifth * inverse) & mask) ~ fourth
            for third = 0, 255 do
                local before_third = ((before_fourth * inverse) & mask) ~ third
                local first_two = forward[before_third]
                if first_two then
                    local suffix = first_two .. string.char(third, fourth, fifth)
                    if suffix ~= original_suffix then
                        return prefix .. suffix
                    end
                end
            end
        end
    end
    error("failed to construct an FNV-1a collision")
end

test("sha256 known vectors", function()
    local hash = require("luainstaller.hash")
    assertEqual(
        hash.sha256(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty vector"
    )
    assertEqual(
        hash.sha256("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "abc vector"
    )
    assertEqual(
        hash.sha256("The quick brown fox jumps over the lazy dog"),
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
        "quick-brown-fox vector"
    )
end)

test("sha256 matches the host across block boundaries and binary data", function()
    local available = os.execute("command -v sha256sum >/dev/null 2>&1")
    if available ~= true and available ~= 0 then
        return
    end
    local root = makeTempDir("sha256-differential")
    local hash = require("luainstaller.hash")
    local sizes = {
        0, 1, 31, 55, 56, 57, 63, 64, 65,
        127, 128, 129, 1000, 1024 * 1024,
    }
    for _, size in ipairs(sizes) do
        local bytes = {}
        for index = 1, size do
            bytes[index] = string.char((index * 131 + 17) % 256)
        end
        local content = table.concat(bytes)
        local path = root .. "/fixture-" .. size .. ".bin"
        writeFile(path, content)
        local expected = commandOutputTrimmed("sha256sum " .. shellQuote(path)):match("^[0-9a-f]+")
        assertEqual(hash.sha256(content), expected, "SHA-256 size " .. size)
    end
    removeTree(root)
end)

test("checked write reports flush or close failure", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local probe = io.open("/dev/full", "wb")
    if not probe then
        return
    end
    probe:close()

    local fs = require("luainstaller.fs")
    local ok, err = fs.writeFile("/dev/full", "not silently successful")
    assert(ok == nil)
    assert(type(err) == "string" and err ~= "")
end)

test("path roots and safe relatives", function()
    local path = require("luainstaller.path")
    assertEqual(path.dirname("/main.lua"), "/", "POSIX root parent")
    assertEqual(path.dirname("C:/main.lua"), "C:/", "drive root parent")
    assertEqual(path.dirname("//server/share.lua"), "//server", "UNC parent")
    assertEqual(path.join("/", "main.lua"), "/main.lua", "POSIX root join")
    assertEqual(path.join("C:/", "main.lua"), "C:/main.lua", "drive root join")
    assert(path.isWithin("foo/bar", "."))
    assert(path.isWithin("/foo", "/"))
    assert(path.isWithin("C:/foo", "C:/"))
    assert(not path.isWithin("../foo", "."))
    assert(not path.isSafeRelative("C:relative"))
    assert(not path.isSafeRelative("trailing/"))
    assert(not path.isSafeRelative("a//b"))
    assert(path.isSafeRelative("a/b.lua"))
end)

test("API rejects non-file and non-finite inputs", function()
    local luainstaller = require("luainstaller")
    local entry_directory = luainstaller.analyze({ entry = "test" })
    assert(not entry_directory.ok)
    assertEqual(entry_directory.error.type, "ScriptNotFoundError", "directory entry")

    local infinite = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        max_deps = math.huge,
    })
    assert(not infinite.ok)
    assertEqual(infinite.error.type, "InvalidOptionsError", "infinite max_deps")

    local nan = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        max_deps = 0 / 0,
    })
    assert(not nan.ok)
    assertEqual(nan.error.type, "InvalidOptionsError", "NaN max_deps")

    local default_target = luainstaller.compatibility({
        entry = "test/single_file/01_hello_luainstaller.lua",
    })
    local empty_target = luainstaller.compatibility({
        entry = "test/single_file/01_hello_luainstaller.lua",
        target_os = "",
    })
    assert(default_target.ok and empty_target.ok, "empty target_os compatibility failed")
    assertEqual(
        empty_target.compatibility.target.os,
        default_target.compatibility.target.os,
        "empty target_os default"
    )
end)

test("API rejects unsafe string and manual include inputs", function()
    local luainstaller = require("luainstaller")
    local root = makeTempDir("input-validation")
    local text_path = root .. "/notes.txt"
    writeFile(text_path, "not Lua source\n")

    local include_directory = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        include = { root },
    })
    assert(not include_directory.ok)
    assertEqual(include_directory.error.type, "InvalidOptionsError", "directory include")

    local include_text = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        include = { text_path },
    })
    assert(not include_text.ok)
    assertEqual(include_text.error.type, "InvalidOptionsError", "non-Lua include")

    local nul_output = luainstaller.bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/bad\0output",
    })
    assert(not nul_output.ok)
    assertEqual(nul_output.error.type, "InvalidOptionsError", "NUL output")
    assert(not fileExists(root .. "/bad"))

    local control_output = luainstaller.bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/bad\nparent/output",
    })
    assert(not control_output.ok)
    assertEqual(control_output.error.type, "InvalidOptionsError", "control-byte output")
    assert(not fileExists(root .. "/bad\nparent"))

    local nul_argument = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        run_args = { "bad\0argument" },
    })
    assert(not nul_argument.ok)
    assertEqual(nul_argument.error.type, "InvalidOptionsError", "NUL run argument")

    removeTree(root)
end)

test("API rejects character devices as entry scripts", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local luainstaller = require("luainstaller")
    local result = luainstaller.analyze({ entry = "/dev/null" })
    assert(not result.ok)
    assertEqual(result.error.type, "ScriptNotFoundError", "device entry")
end)

test("require lexer matches legal Lua literal forms", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    local cases = {
        {
            name = "quoted basic",
            source = "local value = require 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "line comment before argument",
            source = "local value = require -- comment\n 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "block comment before argument",
            source = "local value = require --[=[ comment ]=] 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "comment inside parentheses",
            source = "local value = require( -- comment\n 'foo')",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "pcall comments",
            source = "local ok, value = pcall( -- first\n require, -- second\n 'foo')",
            expected = { { name = "foo", line = 2, optional = true } },
        },
        {
            name = "form feed whitespace",
            source = "local value = require\f'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "vertical tab whitespace",
            source = "local value = require\v'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "long string initial newline",
            source = "local value = require [=[\nfoo]=]",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "long string CRLF normalization",
            source = "local value = require [=[\r\nfoo\r\nbar]=]",
            expected = { { name = "foo\nbar", line = 1 } },
        },
        {
            name = "escaped newline line tracking",
            source = "local a = require 'fo\\\no'\nlocal b = require 'bar'",
            expected = {
                { name = "fo\no", line = 1 },
                { name = "bar", line = 3 },
            },
        },
        {
            name = "result concatenation",
            source = "local value = require 'foo' .. suffix",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "vararg before require",
            source = "local first = ...\nrequire 'foo'",
            expected = { { name = "foo", line = 2 } },
        },
    }

    for _, case in ipairs(cases) do
        assert(load(case.source, "=" .. case.name, "t", {}), case.name)
        local actual = LuaLexer.new(case.source, case.name):extractRequires()
        assertEqual(#actual, #case.expected, case.name .. " count")
        for index, expected in ipairs(case.expected) do
            assertEqual(actual[index].name, expected.name, case.name .. " name")
            assertEqual(actual[index].line, expected.line, case.name .. " line")
            assertEqual(actual[index].optional == true, expected.optional == true, case.name .. " optional")
        end
    end
end)

test("static bundle includes a require after a vararg expression", function()
    local root = makeTempDir("vararg-require")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    writeFile(entry, [[
local first = ...
require("dependency")
assert(ELLIPSIS_DEPENDENCY == 73)
assert(first == nil or type(first) == "string")
]])
    writeFile(dependency, "ELLIPSIS_DEPENDENCY = 73\n")

    local bundled = require("luainstaller").bundle({
        entry = entry,
        out = root .. "/out",
    })
    assert(bundled.ok, bundled.error and bundled.error.message)
    runCommand(shellQuote(bundled.executable))
    removeTree(root)
end)

test("require lexer ignores identifier references and declarations", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    local sources = {
        "local saved = require; return saved",
        "if require then return true end",
        "local function require(name) return name end",
        "function require(name) return name end",
        "require = function(name) return name end",
        "local a, require = 1, function() end",
        "function consume(require) return require end",
        "local function pcall(require, name) return require, name end",
        "function pcall(require, name) return require, name end",
        "return object.require('foo')",
        "return object:require('foo')",
        "return object . require ('foo')",
        "return object : require ('foo')",
        "function object . require(name) return name end",
        "return object . pcall(require, 'foo')",
    }
    for _, source in ipairs(sources) do
        assert(load(source, "=reference", "t", {}), source)
        local actual = LuaLexer.new(source, "reference.lua"):extractRequires()
        assertEqual(#actual, 0, source)
    end
end)

test("require lexer rejects computed call arguments", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    for _, source in ipairs({
        "return require(name)",
        "return require('foo' .. suffix)",
        "return pcall(require, name)",
        "return pcall(require, 'foo' .. suffix)",
    }) do
        assert(load(source, "=computed", "t", {}), source)
        local ok, err = pcall(function()
            return LuaLexer.new(source, "computed.lua"):extractRequires()
        end)
        assert(not ok, source)
        assert(type(err) == "table" and err.type == "DynamicRequireError", source)
    end
end)

test("invalid Lua never produces a bundle", function()
    local root = makeTempDir("invalid-lua")
    local entry = root .. "/main.lua"
    local out = root .. "/out"
    writeFile(entry, "local broken =")

    local luainstaller = require("luainstaller")
    local analyzed = luainstaller.analyze({ entry = entry })
    assert(not analyzed.ok)
    assertEqual(analyzed.error.type, "LuaSyntaxError", "analyze syntax error")

    local bundled = luainstaller.bundle({ entry = entry, out = out })
    assert(not bundled.ok)
    assertEqual(bundled.error.type, "LuaSyntaxError", "bundle syntax error")
    assert(not fileExists(out))

    removeTree(root)
end)

test("manual include syntax is validated", function()
    local root = makeTempDir("invalid-include")
    local included = root .. "/broken.lua"
    writeFile(included, "return function(")
    local result = require("luainstaller").analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        discovery_mode = "manual",
        include = { included },
    })
    assert(not result.ok)
    assertEqual(result.error.type, "LuaSyntaxError", "include syntax error")
    removeTree(root)
end)

test("BOM and shebang normalization preserves source lines", function()
    local analyzer = require("luainstaller.analyzer")
    local runtime = require("luainstaller.runtime")
    local source = "\239\187\191#!/usr/bin/env lua require('not-a-module')\r\nreturn 7"
    local prepared = analyzer.prepareSource(source)
    assertEqual(prepared:sub(1, 1), "\n", "prepared shebang newline")
    assert(load(prepared, "=prepared", "t", {}))
    assertEqual(#analyzer.LuaLexer.new(source, "shebang.lua"):extractRequires(), 0, "shebang requires")
    assertEqual(runtime.stripSource(source):sub(1, 1), "\n", "runtime shebang newline")
end)

test("bit32 is resolved as an external Lua 5.4 module", function()
    local root = makeTempDir("bit32-module")
    local entry = root .. "/main.lua"
    local module = root .. "/bit32.lua"
    writeFile(entry, "return require('bit32')")
    writeFile(module, "return { external = true }")
    local result = require("luainstaller").analyze({ entry = entry })
    assert(result.ok, result.error and result.error.message)
    assertEqual(#result.dependencies.scripts, 1, "bit32 dependency count")
    assertEqual(result.dependencies.scripts[1], module, "bit32 dependency path")
    removeTree(root)
end)

test("runtime discovery uses the real loader path", function()
    local root = makeTempDir("runtime-loader")
    local entry_dir = root .. "/entry"
    local alt_dir = root .. "/alt"
    makeDirectory(entry_dir)
    makeDirectory(alt_dir)
    writeFile(entry_dir .. "/choice.lua", "return 'entry'\n")
    writeFile(alt_dir .. "/choice.lua", "return 'alt'\n")
    writeFile(entry_dir .. "/consumer.lua", "local value = require('choice')\nreturn value\n")
    writeFile(entry_dir .. "/main.lua", string.format(
        "package.path = %q .. package.path\nassert(require('choice') == 'alt')\nassert(require('consumer') == 'alt')\n",
        alt_dir .. "/?.lua;"
    ))

    local analyzed = require("luainstaller").analyze({
        entry = entry_dir .. "/main.lua",
        discovery_mode = "runtime",
    })
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    assertEqual(#analyzed.dependencies.scripts, 2, "runtime dependency count")
    local dependency_set = {}
    for _, dependency in ipairs(analyzed.dependencies.scripts) do
        dependency_set[dependency] = true
    end
    assert(dependency_set[alt_dir .. "/choice.lua"], "actual loader path missing")
    assert(dependency_set[entry_dir .. "/consumer.lua"], "consumer loader path missing")
    assert(not dependency_set[entry_dir .. "/choice.lua"], "cached require used a false fallback path")
    local trace = analyzed.trace[1]
    assertEqual(trace.selected_path, alt_dir .. "/choice.lua", "trace loader path")

    removeTree(root)
end)

test("runtime discovery rejects a module rewritten after loading", function()
    local root = makeTempDir("runtime-source-snapshot")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local late_dependency = root .. "/late.lua"
    writeFile(dependency, "return 41\n")
    writeFile(late_dependency, "return 99\n")
    writeFile(entry, string.format([[
assert(require("dependency") == 41)
local out = assert(io.open(%q, "wb"))
assert(out:write("return require('late')\n"))
assert(out:close())
]], dependency))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted bytes it did not execute")
    assertEqual(analyzed.error.type, "SourceChangedError", "runtime source snapshot")
    removeTree(root)
end)

test("runtime discovery rejects filesystem modules cached before tracing", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cached-module")
    local entry = root .. "/main.lua"
    local cached = root .. "/cached.lua"
    local helper = root .. "/helper.lua"
    local init = root .. "/init.lua"
    local wrapper = root .. "/lua-with-init"
    writeFile(cached, "return require('helper')\n")
    writeFile(helper, "return 73\n")
    writeFile(entry, string.format([[
local out = assert(io.open(%q, "wb"))
assert(out:write("return 99\n"))
assert(out:close())
assert(require('cached') == 73)
]], cached))
    writeFile(init, string.format(
        "package.path = %q .. package.path\nrequire('cached')\n",
        root .. "/?.lua;"
    ))
    writeFile(wrapper, table.concat({
        "#!/bin/sh",
        "LUA_INIT=" .. shellQuote("@" .. init),
        "export LUA_INIT",
        "exec " .. shellQuote(commandOutputTrimmed("command -v lua")) .. " \"$@\"",
        "",
    }, "\n"))
    runCommand("chmod 700 " .. shellQuote(wrapper))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
        lua = wrapper,
    })
    assert(not analyzed.ok, "runtime discovery accepted an unsnapshotted cached module")
    assertEqual(analyzed.error.type, "DiscoveryError", "cached runtime module")
    removeTree(root)
end)

test("runtime discovery rejects builtin names cached before tracing", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cached-builtin")
    local entry = root .. "/main.lua"
    local init = root .. "/init.lua"
    local wrapper = root .. "/lua-with-init"
    writeFile(entry, "assert(require('math') == 88)\n")
    writeFile(init, "package.loaded.math = 88\n")
    writeFile(wrapper, table.concat({
        "#!/bin/sh",
        "LUA_INIT=" .. shellQuote("@" .. init),
        "export LUA_INIT",
        "exec " .. shellQuote(commandOutputTrimmed("command -v lua")) .. " \"$@\"",
        "",
    }, "\n"))
    runCommand("chmod 700 " .. shellQuote(wrapper))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
        lua = wrapper,
    })
    assert(not analyzed.ok, "runtime discovery accepted a builtin replaced before tracing")
    assertEqual(analyzed.error.type, "DiscoveryError", "cached builtin runtime module")
    removeTree(root)
end)

test("runtime discovery rejects a filesystem fallback for a preload loader", function()
    local root = makeTempDir("runtime-preload-shadow")
    local entry = root .. "/main.lua"
    writeFile(root .. "/shadow.lua", "return 99\n")
    writeFile(entry, [[
package.preload.shadow = function() return 41 end
assert(require("shadow") == 41)
]])

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery substituted a file for a preload loader")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime preload fallback")
    removeTree(root)
end)

test("runtime discovery rejects custom native loader paths", function()
    local root = makeTempDir("runtime-native-snapshot")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    writeFile(native, "native bytes that returned 41\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        return function() return 41 end, %q
    end
    return "\n\tno fixture module " .. tostring(name)
end)
assert(require("swap") == 41)
local out = assert(io.open(%q, "wb"))
assert(out:write("replacement bytes that return 99\n"))
assert(out:close())
]], native, native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes it did not execute")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime custom native loader")
    removeTree(root)
end)

test("runtime discovery rejects a C loader without loader data", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-native-no-loader-data")
    local entry = root .. "/main.lua"
    local native = root .. "/shadow.so"
    local native_source = root .. "/shadow.c"
    writeFile(native_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_shadow(lua_State *state) { lua_pushinteger(state, 88); return 1; }
]])
    runCommand("cc -std=c11 -Wall -Wextra -Werror -pedantic -shared -fPIC "
        .. shellQuote(native_source) .. " -o " .. shellQuote(native)
        .. " $(pkg-config --cflags --libs lua)")
    writeFile(entry, string.format([[
package.loaded.math = nil
table.insert(package.searchers, 1, function(name)
    if name == "math" then
        return assert(package.loadlib(%q, "luaopen_shadow"))
    end
    return "\n\tfixture searcher miss"
end)
assert(require("math") == 88)
]], native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted a C loader without provenance")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime C loader without data")
    removeTree(root)
end)

test("runtime discovery rejects a loader from a searcher inserted during require", function()
    local root = makeTempDir("runtime-inserted-searcher")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
package.loaded.math = nil
local searchers = package.searchers
table.insert(searchers, 1, function(name)
    if name == "math" then
        table.insert(searchers, 2, function(inserted_name)
            if inserted_name == "math" then
                return function() return 88 end
            end
            return "\n\tinserted searcher miss"
        end)
    end
    return "\n\tinserting searcher miss"
end)
assert(require("math") == 88)
]])

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted an unwrapped loader without provenance")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime inserted searcher")
    removeTree(root)
end)

test("runtime discovery rejects a loader with a substituted environment", function()
    local root = makeTempDir("runtime-loader-environment")
    local entry = root .. "/main.lua"
    local dependency = root .. "/choice.lua"
    writeFile(dependency, "return VALUE\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "choice" then
        return assert(loadfile(%q, "t", { VALUE = 99 })), %q
    end
    return "\n\tfixture searcher miss"
end)
assert(require("choice") == 99)
]], dependency, dependency))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted a non-reproducible loader environment")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime loader environment")
    removeTree(root)
end)

test("runtime discovery rejects native paths changed inside a searcher", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-native-pre-snapshot")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    local replacement = root .. "/swap-new.so"
    writeFile(native, "native bytes mapped by the searcher\n")
    writeFile(replacement, "replacement bytes on disk\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        assert(os.rename(%q, %q))
        return function() return 41 end, %q
    end
    return "\n\tno fixture module " .. tostring(name)
end)
assert(require("swap") == 41)
]], replacement, native, native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes changed inside a searcher")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime native searcher mutation")
    removeTree(root)
end)

test("runtime discovery rejects a native loader ABA during dlopen", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-native-aba")
    local entry = root .. "/main.lua"
    local active = root .. "/swap.so"
    local backup = root .. "/swap-original.so"
    local replacement = root .. "/swap-replacement.so"
    local original_source = root .. "/swap-original.c"
    local replacement_source = root .. "/swap-replacement.c"
    writeFile(original_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 41); return 1; }
]])
    writeFile(replacement_source, string.format([[
#include <stdio.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
__attribute__((constructor)) static void restore_original_path(void) {
    if (rename(%q, %q) != 0) _exit(90);
}
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 99); return 1; }
]], backup, active))
    runCommand("cc -std=c11 -Wall -Wextra -Werror -pedantic -shared -fPIC "
        .. shellQuote(original_source) .. " -o " .. shellQuote(active)
        .. " $(pkg-config --cflags --libs lua)")
    runCommand("cc -std=c11 -Wall -Wextra -Werror -pedantic -shared -fPIC "
        .. shellQuote(replacement_source) .. " -o " .. shellQuote(replacement)
        .. " $(pkg-config --cflags --libs lua)")
    writeFile(entry, string.format([[
package.cpath = %q .. package.cpath
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        assert(os.rename(%q, %q))
        assert(os.rename(%q, %q))
    end
    return "\n\tfixture searcher miss"
end)
assert(require("swap") == 99)
]], root .. "/?.so;", active, backup, replacement, active))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes that were not executed")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime native ABA")
    removeTree(root)
end)

test("runtime bundle rejects native modules without provable executed bytes", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-real-native-rejection")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    local native_source = root .. "/swap.c"
    writeFile(native_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 41); return 1; }
]])
    runCommand("cc -std=c11 -Wall -Wextra -Werror -pedantic -shared -fPIC "
        .. shellQuote(native_source) .. " -o " .. shellQuote(native)
        .. " $(pkg-config --cflags --libs lua)")
    writeFile(entry, string.format([[
package.cpath = %q .. package.cpath
assert(require("swap") == 41)
]], root .. "/?.so;"))

    local bundled = require("luainstaller").bundle({
        entry = entry,
        out = root .. "/out",
        discovery_mode = "runtime",
    })
    assert(not bundled.ok, "runtime bundle accepted an unverifiable native loader")
    assertEqual(bundled.error.type, "DiscoveryError", "real runtime native loader")
    assert(bundled.error.message:find("static discovery", 1, true), "native rejection is not actionable")
    assert(not fileExists(root .. "/out"), "rejected runtime bundle published output")
    removeTree(root)
end)

test("runtime discovery rejects a non-5.4 interpreter", function()
    if not os.execute("command -v luajit >/dev/null 2>&1") then
        return
    end
    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        discovery_mode = "runtime",
        lua = "luajit",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "ToolchainError", "runtime interpreter ABI")
end)

test("runtime discovery rejects an incomplete trace", function()
    local root = makeTempDir("runtime-incomplete-trace")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
local original_open = io.open
io.open = function(path, mode)
    if mode ~= "wb" then return original_open(path, mode) end
    local actual = assert(original_open(path, mode))
    local proxy = {}
    function proxy:write() return self end
    function proxy:close() return actual:close() end
    return proxy
end
return true
]])
    local result = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "DiscoveryError", "partial runtime trace")
    removeTree(root)
end)

test("runtime discovery rejects a duplicate completion marker", function()
    local root = makeTempDir("runtime-duplicate-completion")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
local original_open = io.open
io.open = function(path, mode)
    if mode ~= "wb" then return original_open(path, mode) end
    local actual = assert(original_open(path, mode))
    local proxy = {}
    function proxy:write(...)
        local values = table.pack(...)
        assert(actual:write(table.unpack(values, 1, values.n)))
        if values[1] == "LUAINSTALLER_TRACE_V4_COMPLETE" then
            assert(actual:write(table.unpack(values, 1, values.n)))
        end
        return self
    end
    function proxy:flush() return actual:flush() end
    function proxy:close() return actual:close() end
    return proxy
end
return true
]])
    local result = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "DiscoveryError", "duplicate runtime completion")
    removeTree(root)
end)

test("runtime discovery reports temporary directory cleanup failures", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cleanup-failure")
    local success_entry = root .. "/success.lua"
    local failure_entry = root .. "/failure.lua"
    writeFile(success_entry, "return true\n")
    writeFile(failure_entry, "error('injected trace failure')\n")

    local process = require("luainstaller.process")
    local original_output = process.output
    local cleanup_paths = {}
    process.output = function(command)
        if command:match("^rm %-rf ")
            and command:find("luainstaller%-require%-trace%-") then
            local cleanup_path = command:match("^rm %-rf '([^']+)'$")
            cleanup_paths[#cleanup_paths + 1] = cleanup_path
            return false, "injected trace cleanup failure"
        end
        return original_output(command)
    end
    local loaded, isolated_discovery = pcall(dofile, "src/discovery.lua")
    process.output = original_output
    assert(loaded, isolated_discovery)

    local successful_plan, cleanup_err = isolated_discovery.plan({
        entry = success_entry,
        discovery_mode = "runtime",
    })
    local failed_plan, trace_err = isolated_discovery.plan({
        entry = failure_entry,
        discovery_mode = "runtime",
    })
    for _, cleanup_path in ipairs(cleanup_paths) do
        if cleanup_path then runCommand("rm -rf " .. shellQuote(cleanup_path)) end
    end

    assert(not successful_plan, "runtime discovery ignored cleanup failure after success")
    assertEqual(cleanup_err.error.type, "FilesystemError", "runtime cleanup error")
    assert(cleanup_err.error.path:find("luainstaller%-require%-trace%-"))
    assert(not failed_plan, "runtime discovery accepted a failed trace")
    assertEqual(trace_err.error.type, "DiscoveryError", "runtime trace primary error")
    assertEqual(trace_err.error.cleanup_error, "Cannot remove runtime trace directory", "cleanup detail")
    assert(trace_err.error.cleanup_path:find("luainstaller%-require%-trace%-"))
    removeTree(root)
end)

test("runtime run restores bundled module cache entries and all returns", function()
    local runtime = require("luainstaller.runtime")
    local searchers = package.searchers or package.loaders
    local searcher_count = #searchers
    local payload = {
        entry = {
            path = "edge-main.lua",
            source = "local value=require('edge_cache'); return value, nil, 23",
        },
        modules = {
            edge_cache = {
                path = "edge-cache.lua",
                source = "return 17",
            },
        },
    }

    package.loaded.edge_cache = "outer"
    local returned = table.pack(runtime.run(payload))
    assertEqual(returned.n, 3, "return count")
    assertEqual(returned[1], 17, "bundled module value")
    assertEqual(returned[2], nil, "middle nil")
    assertEqual(returned[3], 23, "last return")
    assertEqual(package.loaded.edge_cache, "outer", "existing cache value")
    assertEqual(#searchers, searcher_count, "searcher count")

    package.loaded.edge_cache = nil
    assertEqual(runtime.run(payload), 17, "nil cache payload value")
    assertEqual(package.loaded.edge_cache, nil, "nil cache restored")

    package.loaded.edge_cache = false
    local failing = {
        entry = {
            path = "edge-failure.lua",
            source = "require('edge_cache'); error('edge failure')",
        },
        modules = payload.modules,
    }
    local ok = pcall(runtime.run, failing)
    assert(not ok)
    assertEqual(package.loaded.edge_cache, false, "false cache restored after error")
    assertEqual(#searchers, searcher_count, "searcher count after error")
    package.loaded.edge_cache = nil
end)

test("generated runtime restores module cache and return values", function()
    local root = makeTempDir("generated-runtime-state")
    local entry = root .. "/main.lua"
    local module = root .. "/edge_cache.lua"
    writeFile(entry, "local value=require('edge_cache'); return value, nil, 31\n")
    writeFile(module, "return 29\n")
    local cgen = require("luainstaller.cgen")
    local bootstrap = cgen.generateBootstrap({
        entry = entry,
        dependencies = { scripts = { module }, libraries = {} },
        module_names = { [module] = "edge_cache" },
    })
    local chunk = assert(load(bootstrap, "@generated-runtime-state", "t", _G))
    package.loaded.edge_cache = "outer-generated"
    local returned = table.pack(chunk())
    assertEqual(returned.n, 3, "generated return count")
    assertEqual(returned[1], 29, "generated bundled value")
    assertEqual(returned[2], nil, "generated middle nil")
    assertEqual(returned[3], 31, "generated last return")
    assertEqual(package.loaded.edge_cache, "outer-generated", "generated cache restored")
    package.loaded.edge_cache = nil
    removeTree(root)
end)

test("one source supports every required alias", function()
    for _, mode in ipairs({ "onedir", "onefile" }) do
        for order_index, order in ipairs({ { "pkg", "pkg.init" }, { "pkg.init", "pkg" } }) do
            local root = makeTempDir("alias-" .. mode .. "-" .. tostring(order_index))
            makeDirectory(root .. "/pkg")
            writeFile(root .. "/pkg/init.lua", "return { value = 19 }\n")
            writeFile(root .. "/main.lua", string.format([[
local first = require(%q)
local second = require(%q)
assert(first.value == 19 and second.value == 19)
]], order[1], order[2]))

            local result = require("luainstaller").bundle({
                entry = root .. "/main.lua",
                mode = mode,
                out = root .. "/out",
            })
            assert(result.ok, result.error and result.error.message)
            runCommand(shellQuote(result.executable))
            removeTree(root)
        end
    end
end)

test("static discovery preserves every alias for one native source", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("native-alias")
    makeDirectory(root .. "/pkg")
    writeFile(root .. "/module.c", [[
#include <lua.h>
#include <lauxlib.h>

static int open_alias(lua_State *L) {
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, 37);
    lua_setfield(L, -2, "value");
    return 1;
}

int luaopen_pkg(lua_State *L) { return open_alias(L); }
int luaopen_pkg_init(lua_State *L) { return open_alias(L); }
]])
    runCommand(table.concat({
        "cc -shared -fPIC",
        shellQuote(root .. "/module.c"),
        "-o",
        shellQuote(root .. "/pkg/init.so"),
        "$(pkg-config --cflags --libs lua)",
    }, " "))
    writeFile(root .. "/main.lua", [[
local first = require("pkg")
local second = require("pkg.init")
assert(first.value == 37 and second.value == 37)
]])

    local result = require("luainstaller").bundle({
        entry = root .. "/main.lua",
        out = root .. "/out",
        discovery_mode = "static",
    })
    assert(result.ok, result.error and result.error.message)
    runCommand(shellQuote(result.executable))
    assert(fileExists(root .. "/out/.luai/native/pkg.so"))
    assert(fileExists(root .. "/out/.luai/native/pkg/init.so"))
    removeTree(root)
end)

test("Lua runtime cannot overwrite a native module destination", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local lua_binary = commandOutputTrimmed("command -v lua")
    local ldd = runCommand("ldd " .. shellQuote(lua_binary))
    local runtime_name, runtime_path = ldd:match("(liblua[^%s]*)%s+=>%s+([^%s]+)")
    if not runtime_name or not runtime_path or runtime_path == "not" then return end

    local root = makeTempDir("native-runtime-collision")
    local entry = root .. "/main.lua"
    local collision = root .. "/" .. runtime_name
    local out = root .. "/out"
    writeFile(entry, "return true\n")
    runCommand("cp " .. shellQuote(runtime_path) .. " " .. shellQuote(collision))
    local dependencies = { scripts = {}, libraries = { collision }, trace = {} }
    local built_manifest = require("luainstaller.manifest").build({
        entry = entry,
        mode = "onedir",
        out = out,
        target_os = "linux",
        dependencies = dependencies,
    })
    assert(built_manifest.ok, built_manifest.error and built_manifest.error.message)
    local result = require("luainstaller.bundler").bundleOnedir({
        entry = entry,
        out = out,
        target_os = "linux",
        dependencies = dependencies,
        manifest = built_manifest.manifest,
    })
    assert(not result.ok, "Lua runtime overwrote a native module destination")
    assertEqual(result.error.type, "DuplicateModuleError", "Lua runtime destination collision")
    assert(not fileExists(out .. "/out"), "collision build published an executable")
    removeTree(root)
end)

test("manual init include exposes package aliases", function()
    local root = makeTempDir("manual-init-alias")
    makeDirectory(root .. "/pkg")
    writeFile(root .. "/pkg/init.lua", "return { value = 43 }\n")
    writeFile(root .. "/main.lua", [[
assert(require("pkg").value == 43)
assert(require("pkg.init").value == 43)
]])
    local result = require("luainstaller").bundle({
        entry = root .. "/main.lua",
        out = root .. "/out",
        depscan = false,
        include = { root .. "/pkg/init.lua" },
    })
    assert(result.ok, result.error and result.error.message)
    runCommand(shellQuote(result.executable))
    removeTree(root)
end)

test("external manual init include uses its parent package name", function()
    local root = makeTempDir("external-manual-init-alias")
    local app = root .. "/app"
    local package_dir = root .. "/vendor/pkg"
    makeDirectory(app)
    makeDirectory(root .. "/vendor")
    makeDirectory(package_dir)
    local entry = app .. "/main.lua"
    local included = package_dir .. "/init.lua"
    writeFile(entry, "return true\n")
    writeFile(included, "return { value = 47 }\n")

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        depscan = false,
        include = { included },
    })
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    local aliases = {}
    for _, item in ipairs(analyzed.trace) do
        if item.selected_path == included then aliases[item.requested] = true end
    end
    assert(aliases.pkg, "external init.lua lacks its package alias")
    assert(aliases["pkg.init"], "external init.lua lacks its explicit init alias")
    assert(not aliases.init and not aliases["init.init"], "external init.lua used generic aliases")
    removeTree(root)
end)

test("manual include deduplicates an automatic dependency", function()
    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        include = { "test/runtime_bundle/greeter.lua" },
    })
    assert(result.ok, result.error and result.error.message)
    assertEqual(#result.dependencies.scripts, 1, "canonical include count")
end)

test("Source changed during compiler execution is rejected", function()
    local root = makeTempDir("source-changed")
    local fake_bin = root .. "/bin"
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local out = root .. "/out"
    makeDirectory(fake_bin)
    writeFile(entry, "assert(require('dependency').value == 41)\n")
    writeFile(dependency, "return { value = 41 }\n")
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
printf '%s\n' 'return { value = 99 }' > "$LUAI_MUTATE_SOURCE"
exec "$LUAI_REAL_CC" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/cc"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = %q,
    out = %q,
})
assert(result.ok == false, "source mutation must fail the build")
assert(result.error.type == "SourceChangedError", result.error.type)
assert(io.open(%q, "rb") == nil, "failed build must not publish output")
]], entry, out, out)
    local real_cc = commandOutputTrimmed("command -v cc")
    runCommand(table.concat({
        "LUAI_MUTATE_SOURCE=" .. shellQuote(dependency),
        "LUAI_REAL_CC=" .. shellQuote(real_cc),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        "lua -e " .. shellQuote(child),
    }, " "))
    removeTree(root)
end)

test("Source changed before embedding is rejected", function()
    local root = makeTempDir("source-changed-before-embed")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local out = root .. "/out"
    writeFile(entry, "assert(require('dependency').value == 41)\n")
    writeFile(dependency, "return { value = 41 }\n")

    local manifest = require("luainstaller.manifest")
    local original_build = manifest.build
    manifest.build = function(opts)
        local built = original_build(opts)
        if built.ok then
            writeFile(dependency, "return { value = 99 }\n")
        end
        return built
    end
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = entry,
        out = out,
    })
    manifest.build = original_build

    assert(call_ok, result)
    assert(not result.ok)
    assertEqual(result.error.type, "SourceChangedError", "pre-embed mutation")
    assert(not fileExists(out .. "/out"), "failed build published an executable")
    removeTree(root)
end)

test("Source changed between discovery and manifest creation is rejected", function()
    local root = makeTempDir("source-changed-after-discovery")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local late_dependency = root .. "/late.lua"
    writeFile(entry, "return require('dependency')\n")
    writeFile(dependency, "return 41\n")
    writeFile(late_dependency, "return 99\n")

    local manifest = require("luainstaller.manifest")
    local bundler = require("luainstaller.bundler")
    local original_manifest_build = manifest.build
    local original_bundle_onedir = bundler.bundleOnedir
    local bundler_called = false
    manifest.build = function(opts)
        writeFile(entry, "return require('late')\n")
        return original_manifest_build(opts)
    end
    bundler.bundleOnedir = function()
        bundler_called = true
        return { ok = true }
    end

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = entry,
        out = root .. "/out",
    })
    manifest.build = original_manifest_build
    bundler.bundleOnedir = original_bundle_onedir

    assert(call_ok, result)
    assert(not result.ok, "post-discovery source mutation must fail the build")
    assertEqual(result.error.type, "SourceChangedError", "post-discovery mutation")
    assert(not bundler_called, "unsafe manifest reached the bundler")
    removeTree(root)
end)

test("output ownership is recursive and exact", function()
    local root = makeTempDir("recursive-output-owner")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local user_data = out .. "/.luai/USER-DATA.txt"
    writeFile(user_data, "must survive\n")
    local extra = require("luainstaller").bundle(opts)
    assert(not extra.ok and extra.error.type == "InvalidOutputError")
    assertEqual(readFile(user_data), "must survive\n", "nested user content")
    assert(os.remove(user_data))

    local user_dir = out .. "/.luai/unowned-empty-directory"
    makeDirectory(user_dir)
    local extra_dir = require("luainstaller").bundle(opts)
    assert(not extra_dir.ok and extra_dir.error.type == "InvalidOutputError")
    runCommand("test -d " .. shellQuote(user_dir))
    runCommand("rmdir " .. shellQuote(user_dir))

    local manifest_path = out .. "/.luai/manifest.lua"
    local original_manifest = readFile(manifest_path)
    writeFile(manifest_path, original_manifest .. "-- tampered\n")
    local changed = require("luainstaller").bundle(opts)
    assert(not changed.ok and changed.error.type == "InvalidOutputError")
    assertEqual(readFile(manifest_path), original_manifest .. "-- tampered\n", "tampered manifest")
    writeFile(manifest_path, original_manifest)

    local launcher_path = out .. "/.luai/build/launcher.c"
    local launcher_source = readFile(launcher_path)
    assert(os.remove(launcher_path))
    local missing = require("luainstaller").bundle(opts)
    assert(not missing.ok and missing.error.type == "InvalidOutputError")
    assert(not fileExists(launcher_path), "missing generated file was recreated")
    writeFile(launcher_path, launcher_source)

    if package.config:sub(1, 1) == "/" then
        local link_path = out .. "/.luai/unowned-link"
        runCommand("ln -s " .. shellQuote(manifest_path) .. " " .. shellQuote(link_path))
        local linked = require("luainstaller").bundle(opts)
        assert(not linked.ok and linked.error.type == "InvalidOutputError")
        runCommand("test -L " .. shellQuote(link_path))
        assert(os.remove(link_path))

        local fifo_path = out .. "/.luai/unowned-fifo"
        runCommand("mkfifo " .. shellQuote(fifo_path))
        local fifo = require("luainstaller").bundle(opts)
        assert(not fifo.ok and fifo.error.type == "InvalidOutputError")
        runCommand("test -p " .. shellQuote(fifo_path))
        assert(os.remove(fifo_path))
    end

    local rebuilt = require("luainstaller").bundle(opts)
    assert(rebuilt.ok, rebuilt.error and rebuilt.error.message)
    removeTree(root)
end)

test("output changed during the final rename window is restored", function()
    local root = makeTempDir("output-final-rename-race")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_rename = os.rename
    local injected = false
    rawset(os, "rename", function(from, to)
        if not injected and from == out and tostring(to):find(".luai-backup-", 1, true) then
            injected = true
            writeFile(out .. "/USER-DATA.txt", "must survive final rename race\n")
        end
        return original_rename(from, to)
    end)
    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "final output rename hook did not run")
    assert(not rebuilt.ok, "output changed in the final rename window was replaced")
    assertEqual(rebuilt.error.type, "InvalidOutputError", "final rename race")
    assertEqual(
        readFile(out .. "/USER-DATA.txt"),
        "must survive final rename race\n",
        "final rename race user data"
    )
    runCommand(shellQuote(first.executable))
    removeTree(root)
end)

test("output changed after publication is restored before backup deletion", function()
    local root = makeTempDir("output-backup-delete-race")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_rename = os.rename
    local backup_path
    local injected = false
    rawset(os, "rename", function(from, to)
        if from == out and tostring(to):find(".luai-backup-", 1, true) then
            backup_path = to
        end
        local values = table.pack(original_rename(from, to))
        if values[1] and not injected and to == out
            and tostring(from):find(".luai-staging-", 1, true) then
            assert(backup_path, "backup path was not observed")
            injected = true
            writeFile(backup_path .. "/USER-DATA.txt", "must survive backup cleanup race\n")
        end
        return table.unpack(values, 1, values.n)
    end)
    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "published output rename hook did not run")
    assert(not rebuilt.ok, "backup changed before deletion was discarded")
    assertEqual(rebuilt.error.type, "InvalidOutputError", "backup cleanup race")
    assertEqual(
        readFile(out .. "/USER-DATA.txt"),
        "must survive backup cleanup race\n",
        "backup cleanup race user data"
    )
    runCommand(shellQuote(first.executable))
    removeTree(root)
end)

test("output marker rejects malformed ownership records", function()
    local root = makeTempDir("malformed-output-marker")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local marker_path = out .. "/.luai/generated-output.txt"
    local original = readFile(marker_path)
    local inventory_record = original:match("\n(dir\t[^\n]+)\n")
        or original:match("\n(file\t[^\n]+)\n")
    assert(inventory_record)

    local malformed = {
        {
            name = "wrong output directory",
            content = original:gsub("output_dir=[^\n]+", "output_dir=/not/the/output", 1),
        },
        {
            name = "duplicate output directory",
            content = original .. "output_dir=" .. out .. "\n",
        },
        {
            name = "duplicate inventory record",
            content = original .. inventory_record .. "\n",
        },
        {
            name = "path traversal",
            content = original .. "dir\t../escape\n",
        },
        {
            name = "short digest",
            content = original .. "file\t.luai/short\tabcd\n",
        },
        {
            name = "marker self ownership",
            content = original .. "file\t.luai/generated-output.txt\t"
                .. string.rep("0", 64) .. "\n",
        },
        {
            name = "missing final newline",
            content = original:sub(1, -2),
        },
    }
    for _, case in ipairs(malformed) do
        writeFile(marker_path, case.content)
        local result = require("luainstaller").bundle(opts)
        assert(not result.ok and result.error.type == "InvalidOutputError", case.name)
        assertEqual(readFile(marker_path), case.content, case.name .. " preserved")
    end
    writeFile(marker_path, original)
    local rebuilt = require("luainstaller").bundle(opts)
    assert(rebuilt.ok, rebuilt.error and rebuilt.error.message)
    removeTree(root)
end)

test("legacy v1 output is never overwritten automatically", function()
    local root = makeTempDir("legacy-output")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local marker_path = out .. "/.luai/generated-output.txt"
    local legacy = readFile(marker_path):gsub(
        "^luainstaller%-generated%-output%-v%d+",
        "luainstaller-generated-output-v1"
    )
    writeFile(marker_path, legacy)

    local rebuilt = require("luainstaller").bundle(opts)
    assert(not rebuilt.ok and rebuilt.error.type == "InvalidOutputError")
    assertEqual(readFile(marker_path), legacy, "legacy marker")
    assert(fileExists(first.executable), "legacy executable must survive refusal")
    removeTree(root)
end)

test("manifest and output marker use v2 SHA-256 schema", function()
    local root = makeTempDir("v2-hash-schema")
    local out = root .. "/out"
    local result = require("luainstaller").bundle({
        entry = "test/runtime_bundle/main.lua",
        out = out,
    })
    assert(result.ok, result.error and result.error.message)
    assertEqual(result.manifest.version, 2, "manifest version")
    assertEqual(result.manifest.hash_algorithm, "sha256", "manifest hash algorithm")
    assert(result.manifest.entry.content_hash:match("^[0-9a-f]+$")
        and #result.manifest.entry.content_hash == 64)
    for _, group_name in ipairs({ "lua", "native", "external" }) do
        for _, item in ipairs(result.manifest.modules[group_name] or {}) do
            assert(item.content_hash:match("^[0-9a-f]+$") and #item.content_hash == 64)
        end
    end

    local marker = readFile(out .. "/.luai/generated-output.txt")
    assert(marker:match("^luainstaller%-generated%-output%-v2\n"))
    assert(marker:find("dir\t.luai/build\n", 1, true))
    assert(marker:find("file\t.luai/manifest.lua\t", 1, true))
    for line in marker:gmatch("[^\n]+") do
        local digest = line:match("^file\t[^\t]+\t([0-9a-f]+)$")
        if digest then assertEqual(#digest, 64, "marker SHA-256 length") end
    end
    removeTree(root)
end)

test("unreadable nonempty output is never classified empty", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("unreadable-output")
    local out = root .. "/out"
    makeDirectory(out)
    writeFile(out .. "/sentinel", "keep\n")
    runCommand("chmod 000 " .. shellQuote(out))
    local unreadable = os.execute("test ! -r " .. shellQuote(out))
    if unreadable == true or unreadable == 0 then
        local result = require("luainstaller").bundle({
            entry = "test/single_file/01_hello_luainstaller.lua",
            out = out,
        })
        runCommand("chmod 700 " .. shellQuote(out))
        assert(not result.ok)
        assertEqual(readFile(out .. "/sentinel"), "keep\n", "unreadable sentinel")
    else
        runCommand("chmod 700 " .. shellQuote(out))
    end
    removeTree(root)
end)

test("target paths reject Windows hazards and portable collisions", function()
    local path = require("luainstaller.path")
    local hazards = {
        "CON", "con.txt", "aux.txt", "NUL.lua", "PRN", "COM1", "com9.dll",
        "LPT1", "lpt9.txt", "CONIN$", "CONOUT$", "CLOCK$", "nested/AUX.log",
        "a:b", "C:relative", "C:/absolute", "trail.", "trail ", "nested/trail. ",
        "bad?.dll", "bad*.dll", "bad<name", "bad>name", "bad|name", 'bad"name',
        "control\1name", "delete\127name",
    }
    for _, value in ipairs(hazards) do
        local ok = path.validateTargetRelative(value, "windows")
        assert(not ok, "Windows target path accepted: " .. value)
    end
    for _, value in ipairs({ "normal.dll", "nested/Core-1.dll", "COM0", "COM10.dll" }) do
        local ok = path.validateTargetRelative(value, "windows")
        assert(ok, "Windows target path rejected: " .. value)
    end
    for _, target_os in ipairs({ "windows", "macos" }) do
        local ok = path.validateTargetRelative("native/Ä.so", target_os)
        assert(not ok, target_os .. " target accepted a path without reliable case folding")
    end
    assertEqual(
        path.targetKey("A/Core.dll", "windows"),
        path.targetKey("a/core.DLL", "windows"),
        "Windows target key"
    )
    assertEqual(
        path.targetKey("A/Core.dylib", "macos"),
        path.targetKey("a/core.DYLIB", "macos"),
        "macOS target key"
    )

    local root = makeTempDir("target-collisions")
    writeFile(root .. "/Core.dll", "first")
    writeFile(root .. "/core.DLL", "second")
    writeFile(root .. "/CON.dll", "reserved")
    local manifest = require("luainstaller.manifest")
    local duplicate = manifest.build({
        entry = "test/single_file/01_hello_luainstaller.lua",
        target_os = "windows",
        dependencies = {
            scripts = {},
            libraries = { root .. "/Core.dll", root .. "/core.DLL" },
        },
    })
    assert(not duplicate.ok and duplicate.error.type == "DuplicateModuleError")
    local reserved = manifest.build({
        entry = "test/single_file/01_hello_luainstaller.lua",
        target_os = "windows",
        dependencies = { scripts = {}, libraries = { root .. "/CON.dll" } },
    })
    assert(not reserved.ok and reserved.error.type == "InvalidOptionsError")
    removeTree(root)
end)

test("host mac defaults to static launcher profile and target metadata", function()
    local platform = require("luainstaller.platform")
    local manifest = require("luainstaller.manifest")
    local compat = require("luainstaller.compat")
    local original_detect = platform.detectHost
    platform.detectHost = function()
        return { os = "macos", arch = "arm64" }
    end
    local call_ok, built, diagnosed = pcall(function()
        local result = manifest.build({
            entry = "test/single_file/01_hello_luainstaller.lua",
            dependencies = { scripts = {}, libraries = {} },
        })
        return result, compat.diagnose({ dependencies = { libraries = {} } })
    end)
    platform.detectHost = original_detect
    assert(call_ok, built)
    assert(built.ok, built.error and built.error.message)
    assertEqual(built.manifest.launcher.profile, "static-lua", "mac launcher profile")
    assertEqual(built.manifest.platform.host.os, "macos", "manifest host OS")
    assertEqual(built.manifest.platform.host.arch, "arm64", "manifest host arch")
    assertEqual(built.manifest.platform.target.os, "macos", "manifest target OS")
    assertEqual(built.manifest.platform.target.arch, "arm64", "manifest target arch")
    assertEqual(diagnosed.target.launcher_profile, "static-lua", "compat launcher profile")
    assertEqual(diagnosed.target.arch, "arm64", "compat target arch")

    local lied = require("luainstaller").analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        launcher_profile = "not-a-real-profile",
    })
    assert(not lied.ok and lied.error.type == "InvalidOptionsError")
    assertEqual(lied.error.option, "launcher_profile", "launcher profile option")
end)

test("macOS bundle rejects a non-macOS build host", function()
    if commandOutputTrimmed("uname -s") == "Darwin" then return end
    local root = makeTempDir("macos-host-gate")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/out",
        target_os = "macos",
        lua_prefix = root .. "/not-a-prefix",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "UnsupportedPlatformError", "macOS build host gate")
    removeTree(root)
end)

test("unsafe output is rejected before platform and toolchain probes", function()
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = ".",
        target_os = "macos",
        lua_prefix = "/tmp/luainstaller-missing-lua-prefix",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "InvalidOutputError", "unsafe output validation order")
end)

test("onedir rejects an executable collision with metadata directory", function()
    local root = makeTempDir("metadata-executable-collision")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/.luai",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "InvalidOptionsError", "reserved onedir executable")
    assert(not fileExists(root .. "/.luai"), "reserved output was partially published")
    removeTree(root)
end)

test("pkg-config Lua ABI mismatch stops before compiler invocation", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("pkg-config-abi")
    local fake_bin = root .. "/bin"
    local compiler_marker = root .. "/compiler-called"
    local out = root .. "/out"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/pkg-config", [[#!/bin/sh
if [ "$1" = "--modversion" ]; then
    printf '%s\n' '5.3.6'
    exit 0
fi
exec "$LUAI_REAL_PKG_CONFIG" "$@"
]])
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
: > "$LUAI_COMPILER_MARKER"
exec "$LUAI_REAL_CC" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/pkg-config")
        .. " " .. shellQuote(fake_bin .. "/cc"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
})
assert(result.ok == false, "Lua 5.3 pkg-config metadata must fail")
assert(result.error.type == "ToolchainError", result.error.type)
assert(io.open(%q, "rb") == nil, "compiler was invoked before ABI rejection")
]], out, compiler_marker)
    runCommand(table.concat({
        "LUAI_REAL_PKG_CONFIG=" .. shellQuote(commandOutputTrimmed("command -v pkg-config")),
        "LUAI_REAL_CC=" .. shellQuote(commandOutputTrimmed("command -v cc")),
        "LUAI_COMPILER_MARKER=" .. shellQuote(compiler_marker),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        "lua -e " .. shellQuote(child),
    }, " "))
    assert(not fileExists(out .. "/out"), "ABI failure published an executable")
    removeTree(root)
end)

test("linked Lua runtime must report the 5.4 ABI", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("linked-lua-abi")
    local fake_bin = root .. "/bin"
    local fake_lib = root .. "/lib"
    local stub_c = root .. "/lua-stub.c"
    local out = root .. "/out"
    makeDirectory(fake_bin)
    makeDirectory(fake_lib)
    writeFile(stub_c, [[
typedef struct lua_State { int placeholder; } lua_State;
typedef int (*lua_CFunction)(lua_State *);
lua_State *luaL_newstate(void) { static lua_State state; return &state; }
void luaL_openlibs(lua_State *state) { (void)state; }
void lua_close(lua_State *state) { (void)state; }
int lua_getglobal(lua_State *state, const char *name) { (void)state; (void)name; return 4; }
const char *lua_tolstring(lua_State *state, int index, unsigned long *size) {
    (void)state; (void)index; if (size) *size = 7; return "Lua 5.3";
}
void lua_settop(lua_State *state, int index) { (void)state; (void)index; }
int luaL_callmeta(lua_State *state, int index, const char *name) {
    (void)state; (void)index; (void)name; return 0;
}
int lua_type(lua_State *state, int index) { (void)state; (void)index; return 4; }
void luaL_traceback(lua_State *state, lua_State *from, const char *message, int level) {
    (void)state; (void)from; (void)message; (void)level;
}
int lua_gettop(lua_State *state) { (void)state; return 0; }
void lua_createtable(lua_State *state, int array, int records) {
    (void)state; (void)array; (void)records;
}
const char *lua_pushstring(lua_State *state, const char *value) { (void)state; return value; }
void lua_rawseti(lua_State *state, int index, long long key) {
    (void)state; (void)index; (void)key;
}
void lua_setglobal(lua_State *state, const char *name) { (void)state; (void)name; }
void lua_pushcclosure(lua_State *state, lua_CFunction function, int upvalues) {
    (void)state; (void)function; (void)upvalues;
}
int luaL_loadbufferx(lua_State *state, const char *buffer, unsigned long size,
    const char *name, const char *mode) {
    (void)state; (void)buffer; (void)size; (void)name; (void)mode; return 0;
}
int lua_pcallk(lua_State *state, int arguments, int results, int error_function,
    long context, void *continuation) {
    (void)state; (void)arguments; (void)results; (void)error_function;
    (void)context; (void)continuation; return 0;
}
]])
    runCommand(table.concat({
        "cc -shared -fPIC",
        shellQuote(stub_c),
        "-Wl,-soname,liblua-fake.so",
        "-o",
        shellQuote(fake_lib .. "/liblua-fake.so"),
    }, " "))
    writeFile(fake_bin .. "/pkg-config", string.format([[#!/bin/sh
if [ "$1" = "--modversion" ]; then
    printf '%%s\n' '5.4.99'
    exit 0
fi
if [ "$1" = "--cflags" ]; then
    printf '%%s\n' '-I%s -L%s -Wl,-rpath,%s -llua-fake -lm -ldl'
    exit 0
fi
exit 2
]], commandOutputTrimmed("pkg-config --variable=includedir lua"), fake_lib, fake_lib))
    runCommand("chmod 700 " .. shellQuote(fake_bin .. "/pkg-config"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
})
assert(result.ok == false, "misreported linked Lua runtime was accepted")
assert(result.error.type == "ToolchainError", result.error.type)
assert(result.error.message:find("linked Lua runtime", 1, true), result.error.message)
]], out)
    runCommand(table.concat({
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        "lua -e " .. shellQuote(child),
    }, " "))
    assert(not fileExists(out .. "/out"), "ABI probe failure published an executable")
    removeTree(root)
end)

test("linked ABI probe cannot collide with the output executable", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("linked-abi-probe-name")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/lua-abi-probe",
    })
    assert(result.ok, result.error and result.error.message)
    assert(fileExists(result.executable), "ABI probe removed the output executable")
    runCommand(shellQuote(result.executable))
    removeTree(root)
end)

test("target launcher enforces Lua 5.4 headers", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("launcher-abi-guard")
    local include_dir = root .. "/include"
    local c_path = root .. "/launcher.c"
    local log_path = root .. "/compiler.log"
    makeDirectory(include_dir)
    writeFile(include_dir .. "/lua.h", [[
#include_next <lua.h>
#undef LUA_VERSION_NUM
#define LUA_VERSION_NUM 503
]])
    local generated = require("luainstaller.launcher").generateSource({
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
    })
    assert(generated:find("LUA_VERSION_NUM != 504", 1, true))
    assert(generated:find("luai_runtime_is_54", 1, true))
    assert(readFile("src/launcher/luai_launcher.c"):find("LUA_VERSION_NUM != 504", 1, true))
    assert(readFile("src/launcher/luai_launcher.c"):find("luai_runtime_is_54", 1, true))
    writeFile(c_path, generated)
    local compiled = os.execute(table.concat({
        "cc -std=c11 -Wall -Wextra -Werror -pedantic -fsyntax-only",
        "-I" .. shellQuote(include_dir),
        shellQuote(c_path),
        "$(pkg-config --cflags lua)",
        ">" .. shellQuote(log_path) .. " 2>&1",
    }, " "))
    assert(compiled ~= true and compiled ~= 0, "Lua 5.3 headers passed the launcher guard")
    assert(readFile(log_path):find("luainstaller requires Lua 5.4 headers", 1, true))
    removeTree(root)
end)

test("onefile repeated builds are byte identical", function()
    local root = makeTempDir("onefile-reproducible")
    local out = root .. "/app"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local first_bytes = readFile(out)
    assert(os.remove(out))
    local second = require("luainstaller").bundle(opts)
    assert(second.ok, second.error and second.error.message)
    assert(readFile(out) == first_bytes, "onefile bytes differ")
    removeTree(root)
end)

test("onefile cache repairs an equal-size FNV collision and mode", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-cache-exact")
    local cache = root .. "/cache"
    local out = root .. "/app"
    makeDirectory(cache)
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    })
    assert(result.ok, result.error and result.error.message)
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " first")
    local manifest_path = commandOutputTrimmed(
        "find " .. shellQuote(cache) .. " -path '*/.luai/manifest.lua' -type f -print -quit"
    )
    assert(manifest_path ~= "", "extracted manifest not found")
    local original = readFile(manifest_path)
    local collision = fnv1a32Collision(original)
    assert(#collision == #original and collision ~= original)
    assertEqual(
        require("luainstaller.hash").fnv1a32(collision),
        require("luainstaller.hash").fnv1a32(original),
        "FNV collision"
    )
    writeFile(manifest_path, collision)
    runCommand("chmod 700 " .. shellQuote(manifest_path))
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " second")
    assert(readFile(manifest_path) == original, "exact cache repair failed")
    runCommand("test ! -x " .. shellQuote(manifest_path))

    assert(os.remove(manifest_path))
    runCommand("mkfifo " .. shellQuote(manifest_path))
    local fifo_ok, _, fifo_code = os.execute("timeout 5 env TMPDIR=" .. shellQuote(cache)
        .. " " .. shellQuote(out) .. " fifo >/dev/null 2>&1")
    assert(not fifo_ok and fifo_code ~= 124, "extractor blocked on a cache FIFO")
    runCommand("test -p " .. shellQuote(manifest_path))
    assert(os.remove(manifest_path))
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " repaired")
    assert(readFile(manifest_path) == original, "cache did not recover after unsafe entry removal")

    local luai_dir = manifest_path:match("^(.*)/manifest%.lua$")
    local victim = root .. "/symlink-victim"
    makeDirectory(victim)
    writeFile(victim .. "/manifest.lua", original)
    runCommand("chmod 700 " .. shellQuote(victim .. "/manifest.lua"))
    runCommand("rm -rf " .. shellQuote(luai_dir))
    runCommand("ln -s " .. shellQuote(victim) .. " " .. shellQuote(luai_dir))
    local linked_ok, _, linked_code = os.execute(
        "timeout 5 env TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out)
            .. " linked-parent >/dev/null 2>&1"
    )
    assert(not linked_ok and linked_code ~= 124, "extractor accepted a linked cache parent")
    assert(readFile(victim .. "/manifest.lua") == original, "linked parent changed victim bytes")
    local executable_victim = os.execute("test -x " .. shellQuote(victim .. "/manifest.lua"))
    assert(executable_victim == true or executable_victim == 0,
        "linked parent changed victim mode before validation")
    removeTree(root)
end)

test("onefile rejects control bytes in the target filename", function()
    local root = makeTempDir("onefile-control-path")
    local out = root .. "/bad\11name"
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    })
    assert(not result.ok and result.error.type == "InvalidOptionsError")
    assert(not fileExists(out), "invalid onefile target was published")
    removeTree(root)
end)

test("onefile cleanup failure reports a committed output", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-committed-cleanup")
    local fake_bin = root .. "/bin"
    local out = root .. "/app"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/rm", [[#!/bin/sh
for value in "$@"; do
    case "$value" in
        *.luai-output-*)
            printf '%s\n' 'injected output-stage cleanup failure' >&2
            exit 73
            ;;
    esac
done
exec "$LUAI_REAL_RM" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/rm"))
    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    mode = "onefile",
    out = %q,
})
assert(result.ok == false, "injected cleanup failure must be reported")
assert(result.error.type == "FilesystemError", result.error.type)
assert(result.error.committed == true, "published output must be marked committed")
assert(result.error.path == %q, "committed output path missing")
]], out, out)
    runCommand(table.concat({
        "LUAI_REAL_RM=" .. shellQuote(commandOutputTrimmed("command -v rm")),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        "lua -e " .. shellQuote(child),
    }, " "))
    assert(fileExists(out), "committed output was lost after cleanup failure")
    runCommand(shellQuote(out) .. " committed")
    removeTree(root)
end)

test("onefile extractor is strict C11 and sanitizer clean", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-strict-extractor")
    local fake_bin = root .. "/bin"
    local captured = root .. "/extractor.c"
    local out = root .. "/app"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
for value in "$@"; do
    case "$value" in
        */extractor.c) cp "$value" "$LUAI_CAPTURE_EXTRACTOR" ;;
    esac
done
exec "$LUAI_REAL_CC" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/cc"))
    local child = harness.loader_prelude() .. string.format([[
local bundler = require("luainstaller.bundler")
local onefile = require("luainstaller.onefile")
local original = bundler.bundleOnedir
bundler.bundleOnedir = function(opts)
    assert(os.execute("mkdir -p " .. require("luainstaller.process").shellQuote(opts.out .. "/utf8-雪")))
    local inner = assert(io.open(opts.out .. "/inner", "wb"))
    assert(inner:write("#!/bin/sh\nexit 0\n"))
    assert(inner:close())
    assert(os.execute("chmod 700 " .. require("luainstaller.process").shellQuote(opts.out .. "/inner")))
    local empty = assert(io.open(opts.out .. "/utf8-雪/empty.bin", "wb"))
    assert(empty:close())
    return { ok = true, executable = opts.out .. "/inner", manifest = opts.manifest }
end
local result = onefile.bundleOnefile({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
    target_os = "linux",
})
bundler.bundleOnedir = original
assert(result.ok, result.error and result.error.message)
]], out)
    runCommand(table.concat({
        "LUAI_CAPTURE_EXTRACTOR=" .. shellQuote(captured),
        "LUAI_REAL_CC=" .. shellQuote(commandOutputTrimmed("command -v cc")),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        "lua -e " .. shellQuote(child),
    }, " "))
    assert(fileExists(captured), "extractor C source was not captured")
    local source = readFile(captured)
    assert(source:find("#define _DARWIN_C_SOURCE 1", 1, true),
        "extractor does not expose Darwin no-follow flags under strict C11")
    assert(source:find('#define LUAI_INNER_EXE "\\', 1, true))
    assert(source:find("CreateProcessA(NULL, cmd, NULL, NULL, FALSE", 1, true))
    assert(source:find("else if (!backslash) pos = slash", 1, true))
    assert(source:match("luai_file_%d+, 0, 0 }"), "empty file record missing")

    local gcc_exe = root .. "/extractor-gcc"
    runCommand(table.concat({
        "cc -std=c11 -Wall -Wextra -Werror -pedantic",
        shellQuote(captured),
        "-o",
        shellQuote(gcc_exe),
    }, " "))
    local gcc_cache = root .. "/gcc-cache"
    makeDirectory(gcc_cache)
    runCommand("TMPDIR=" .. shellQuote(gcc_cache) .. " " .. shellQuote(gcc_exe))

    local mingw = os.execute("command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1")
    if mingw == true or mingw == 0 then
        local windows_one = root .. "/extractor-windows-1.exe"
        local windows_two = root .. "/extractor-windows-2.exe"
        local windows_command = table.concat({
            "x86_64-w64-mingw32-gcc -std=c11 -Wall -Wextra -Werror -pedantic",
            shellQuote(captured),
            "-o",
            "%s",
            "-static-libgcc -Wl,--no-insert-timestamp -ladvapi32",
        }, " ")
        runCommand(string.format(windows_command, shellQuote(windows_one)))
        runCommand(string.format(windows_command, shellQuote(windows_two)))
        assert(readFile(windows_one) == readFile(windows_two), "MinGW extractor is not reproducible")
    end

    local clang = os.execute("command -v clang >/dev/null 2>&1")
    if clang == true or clang == 0 then
        local clang_exe = root .. "/extractor-clang"
        runCommand(table.concat({
            "clang -std=c11 -Wall -Wextra -Werror -pedantic",
            "-fsanitize=address,undefined -fno-omit-frame-pointer",
            shellQuote(captured),
            "-o",
            shellQuote(clang_exe),
        }, " "))
        local clang_cache = root .. "/clang-cache"
        makeDirectory(clang_cache)
        runCommand("ASAN_OPTIONS=detect_leaks=1 TMPDIR=" .. shellQuote(clang_cache)
            .. " " .. shellQuote(clang_exe))
    end
    removeTree(root)
end)

test("logger retains concurrent writers", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-concurrency")
    local home = root .. "/home"
    makeDirectory(home)

    local workers = {
        "#!/bin/sh",
        "status=0",
        "pids=",
    }
    for index = 1, 60 do
        local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
assert(logger.logInfo("edge", "parallel", %q) == true)
]], "worker-" .. index)
        workers[#workers + 1] = table.concat({
            "HOME=" .. shellQuote(home),
            "lua -e " .. shellQuote(child),
            "&",
        }, " ")
        workers[#workers + 1] = 'pids="$pids $!"'
    end
    workers[#workers + 1] = 'for pid in $pids; do wait "$pid" || status=1; done'
    workers[#workers + 1] = 'exit "$status"'

    local worker_script = root .. "/workers.sh"
    writeFile(worker_script, table.concat(workers, "\n") .. "\n")
    runCommand("chmod 700 " .. shellQuote(worker_script))
    runCommand(shellQuote(worker_script))

    local verify = harness.loader_prelude() .. [[
local logs = require("luainstaller.logger").getLogs({ descending = false })
assert(#logs == 60, "expected 60 retained logs, got " .. tostring(#logs))
local seen = {}
for _, entry in ipairs(logs) do
    assert(entry.source == "edge" and entry.action == "parallel")
    assert(not seen[entry.message], "duplicate worker log: " .. tostring(entry.message))
    seen[entry.message] = true
end
for index = 1, 60 do
    assert(seen["worker-" .. index], "missing worker log " .. index)
end
print("logger concurrency ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " lua -e " .. shellQuote(verify))
    assert(output:find("logger concurrency ok", 1, true))
    removeTree(root)
end)

test("logger preserves the previous file on a failed transaction", function()
    local root = makeTempDir("logger-write-failure")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local path = %q
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "preserve", "before") == true)
local input = assert(io.open(path, "rb"))
local original = assert(input:read("*a"))
assert(input:close())
local backup_input = assert(io.open(path .. ".bak", "rb"))
local original_backup = assert(backup_input:read("*a"))
assert(backup_input:close())
assert(type(assert(load(original, "@logs.lua", "t", {}))()) == "table")

local saved_open = io.open
io.open = function(candidate, mode)
    local is_log_write = mode == "wb"
        and (candidate == path or candidate:find("logs.lua.tmp.", 1, true))
    if not is_log_write then
        return saved_open(candidate, mode)
    end
    local real = assert(saved_open(candidate, mode))
    return {
        write = function()
            return nil, "simulated disk full"
        end,
        flush = function()
            return real:flush()
        end,
        close = function()
            return real:close()
        end,
    }
end
assert(logger.clearLogs() == false, "failed transaction must be reported")
io.open = saved_open

local after_handle = assert(io.open(path, "rb"))
local after = assert(after_handle:read("*a"))
assert(after_handle:close())
assert(after == original, "failed transaction changed the primary log")
local backup_after_handle = assert(io.open(path .. ".bak", "rb"))
local backup_after = assert(backup_after_handle:read("*a"))
assert(backup_after_handle:close())
assert(backup_after == original_backup, "failed transaction changed the backup log")
local logs = logger.getLogs({ descending = false })
assert(#logs == 1 and logs[1].message == "before")
print("logger failure preservation ok")
]], home .. "/.luainstaller/logs.lua")
    local output = runCommand("HOME=" .. shellQuote(home) .. " lua -e " .. shellQuote(child))
    assert(output:find("logger failure preservation ok", 1, true))
    removeTree(root)
end)

test("logger clear cannot resurrect entries from its backup", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-clear-backup")
    local script = harness.loader_prelude() .. [[
local logger = require("luainstaller.logger")
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "clear", "sensitive") == true)
assert(logger.clearLogs() == true)
local path = os.getenv("HOME") .. "/.luainstaller/logs.lua"
assert(os.remove(path))
local logs = logger.getLogs()
assert(#logs == 0, "cleared backup resurrected " .. tostring(#logs) .. " entries")
print("logger clear backup ok")
]]
    local output = runCommand("HOME=" .. shellQuote(root) .. " lua -e " .. shellQuote(script))
    assert(output:find("logger clear backup ok", 1, true))
    removeTree(root)
end)

test("logger times out without releasing another owner lock", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-owned-lock")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local directory = %q
local lock = directory .. "/logs.lua.lock"
assert(os.execute("mkdir -p " .. require("luainstaller.process").shellQuote(lock)))
local content = "created=" .. tostring(os.time()) .. "\ntoken=active-owner\n"
for _, name in ipairs({ "owner", "owner.active-owner" }) do
    local handle = assert(io.open(lock .. "/" .. name, "wb"))
    assert(handle:write(content))
    assert(handle:close())
end
local started = os.time()
assert(logger.clearLogs() == false, "active lock must not be stolen")
assert(os.time() - started >= 4, "lock acquisition returned before its timeout")
for _, name in ipairs({ "owner", "owner.active-owner" }) do
    local handle = assert(io.open(lock .. "/" .. name, "rb"))
    assert(handle:read("*a") == content, "another owner's lock was changed")
    assert(handle:close())
    assert(os.remove(lock .. "/" .. name))
end
assert(os.remove(lock))
print("logger owned-lock timeout ok")
]], home .. "/.luainstaller")
    local output = runCommand("HOME=" .. shellQuote(home) .. " lua -e " .. shellQuote(child))
    assert(output:find("logger owned-lock timeout ok", 1, true))
    removeTree(root)
end)

test("logger recovers a backup and a stale owned lock", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-recovery")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local directory = %q
local path = directory .. "/logs.lua"
local backup = path .. ".bak"
local lock = path .. ".lock"
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "recover", "before") == true)
assert(os.rename(path, backup))
assert(os.execute("mkdir " .. require("luainstaller.process").shellQuote(lock)))
local owner = assert(io.open(lock .. "/owner", "wb"))
assert(owner:write("created=" .. tostring(os.time() - 1000) .. "\ntoken=abandoned\n"))
assert(owner:close())
assert(logger.logInfo("edge", "recover", "after") == true)
local logs = logger.getLogs({ descending = false })
assert(#logs == 2, "backup recovery lost entries: " .. tostring(#logs))
assert(logs[1].message == "before" and logs[2].message == "after")
local lock_probe = io.open(lock .. "/owner", "rb")
assert(lock_probe == nil, "stale lock remains")
local primary = assert(io.open(path, "rb"))
assert(primary:read(1) ~= nil, "primary log was not restored")
assert(primary:close())
print("logger stale recovery ok")
]], home .. "/.luainstaller")
    local output = runCommand("HOME=" .. shellQuote(home) .. " lua -e " .. shellQuote(child))
    assert(output:find("logger stale recovery ok", 1, true))
    removeTree(root)
end)

test("source installer rejects incompatible Lua before writing", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("installer-lua-abi")
    local fake_lua = root .. "/lua-old"
    local rejected_prefix = root .. "/rejected"
    writeFile(fake_lua, [[#!/bin/sh
printf '%s\n' 'Lua 5.3'
]])
    runCommand("chmod 700 " .. shellQuote(fake_lua))

    local rejected_log = root .. "/rejected.log"
    local ok = os.execute(table.concat({
        "sh tools/install-source.sh --lua " .. shellQuote(fake_lua),
        "--prefix " .. shellQuote(rejected_prefix),
        ">" .. shellQuote(rejected_log) .. " 2>&1",
    }, " "))
    assert(ok ~= true and ok ~= 0, "incompatible Lua unexpectedly installed")
    assert(not fileExists(rejected_prefix .. "/bin/luai"), "installer wrote before ABI rejection")
    assert(readFile(rejected_log):find("Lua 5.4", 1, true), "ABI error was not actionable")

    local prefix = root .. "/accepted"
    runCommand("sh tools/install-source.sh --lua lua --prefix " .. shellQuote(prefix))
    local wrapper_log = root .. "/wrapper.log"
    local wrapper_ok = os.execute(table.concat({
        "LUAI_LUA=" .. shellQuote(fake_lua),
        shellQuote(prefix .. "/bin/luai") .. " -v",
        ">" .. shellQuote(wrapper_log) .. " 2>&1",
    }, " "))
    assert(wrapper_ok ~= true and wrapper_ok ~= 0, "installed wrapper accepted incompatible Lua")
    assert(readFile(wrapper_log):find("Lua 5.4", 1, true), "wrapper ABI error was not actionable")
    removeTree(root)
end)

test("remote scripts are pinned and non-destructive", function()
    local scripts = {
        "tools/remote-test-linux.sh",
        "tools/remote-test-macos.sh",
        "tools/remote-test-windows.sh",
    }
    local contents = {}
    for _, file in ipairs(scripts) do
        local content = readFile(file)
        contents[file] = content
        assert(content:find("require_safe_tmp_path()", 1, true), file .. " lacks path validation")
        assert(content:find("stage_source()", 1, true), file .. " lacks staged downloads")
        assert(content:find("expected=$3", 1, true), file .. " does not accept a pinned hash")
        assert(content:find("sha256sum -c", 1, true), file .. " does not verify SHA-256")
        assert(content:find(".part.$$", 1, true), file .. " does not download atomically")
        assert(not content:find("tar --exclude=.git", 1, true), file .. " archives untracked files")
        assert(content:find(
            "4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae",
            1,
            true
        ), file .. " lacks the Lua source pin")
        assert(content:find(
            "ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82",
            1,
            true
        ), file .. " lacks the lsqlite3 source pin")
        assert(content:find(
            "8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32",
            1,
            true
        ), file .. " lacks the SQLite source pin")
    end

    for _, file in ipairs({ scripts[1], scripts[2] }) do
        local content = contents[file]
        assert(content:find("git ls-files -z", 1, true), file .. " does not stream the tracked tree")
        assert(content:find(
            "b0e0c85205841ddd7be485f53d6125766d18a81d226588d2366931e9a1484492",
            1,
            true
        ), file .. " lacks the LuaRocks source pin")
        for _, pinned in ipairs({
            "lua-cjson 2.1.0.10-1",
            "luafilesystem 1.9.0-1",
            "luasocket 3.1.0-1",
            "mimetypes 1.1.0-2",
            "pegasus 1.1.0-0",
        }) do
            assert(content:find(pinned, 1, true), file .. " lacks dependency pin " .. pinned)
        end
    end

    local linux = contents[scripts[1]]
    assert(linux:find("linux x64 smoke suite reported a skipped probe", 1, true))
    assert(linux:find("ARM64 smoke suite reported a skipped probe", 1, true))

    local macos = contents[scripts[2]]
    assert(macos:find("test/cli_split_smoke.lua", 1, true), "macOS omits the portable CLI suite")
    assert(macos:find("test/contract_docs.lua", 1, true), "macOS omits contract tests")
    assert(macos:find("test/smoke_all.lua", 1, true), "macOS omits the core smoke suite")
    assert(macos:find("macOS smoke suite reported a skipped probe", 1, true))
    assert(macos:find("macOS onefile reproducibility ok", 1, true),
        "macOS omits the repeated onefile byte check")
    local _, luarocks_prefix_assignments = macos:gsub(
        "LUAROCKS_PREFIX=%$%(quote_remote",
        ""
    )
    assertEqual(luarocks_prefix_assignments, 2, "macOS fresh-shell LuaRocks prefix assignments")
    local _, lua_prefix_bindings = macos:gsub("LUAI_LUA_PREFIX=", "")
    assertEqual(lua_prefix_bindings, 3, "macOS fresh-shell build Lua prefix bindings")
    assert(macos:find("export PATH LUA_PATH LUA_CPATH LUAI_LUA_PREFIX", 1, true),
        "macOS fresh shell does not export the build Lua prefix")
    assert(not readFile("src/bundler.lua"):find("-Wl,-no_uuid", 1, true),
        "macOS launcher suppresses the LC_UUID required by modern dyld")
    assert(not readFile("src/onefile.lua"):find("-Wl,-no_uuid", 1, true),
        "macOS extractor suppresses the LC_UUID required by modern dyld")

    local windows = contents[scripts[3]]
    assert(not windows:find("StrictHostKeyChecking=no", 1, true))
    assert(windows:find("StrictHostKeyChecking=yes", 1, true))
    assert(windows:find("SSH_OPTS must not override host-key policy", 1, true))
    assert(windows:find('SSH_OPTS=${SSH_OPTS:-""}', 1, true))
    assert(windows:find('if [ -n "${WINDOWS_PASSWORD:-}" ]', 1, true))
    assert(not windows:find("require_env WINDOWS_PASSWORD", 1, true))
    assert(windows:find('if [ "${WINDOWS_LOCAL_ONLY:-0}" = 1 ]', 1, true))

    local root = makeTempDir("remote-path-guards")
    local victim = root .. "/victim"
    makeDirectory(victim)
    writeFile(victim .. "/sentinel", "preserve\n")
    local cases = {
        "REMOTE_ROOT=/ sh tools/remote-test-linux.sh",
        "REMOTE_ROOT=/ sh tools/remote-test-macos.sh",
        "WIN_OUT=" .. shellQuote(root .. "/stage/../victim")
            .. " sh tools/remote-test-windows.sh",
    }
    for index, command in ipairs(cases) do
        local log = root .. "/guard-" .. index .. ".log"
        local ok = os.execute(command .. " >" .. shellQuote(log) .. " 2>&1")
        assert(ok ~= true and ok ~= 0, "unsafe remote path was accepted: " .. command)
        assert(readFile(log):find("temporary path", 1, true), "path rejection was not actionable")
    end
    assert(readFile(victim .. "/sentinel") == "preserve\n", "unsafe override deleted user data")
    removeTree(root)
end)

local filter = os.getenv("EDGE_FILTER")
local ran = 0

for _, item in ipairs(tests) do
    if not filter or item.name:find(filter, 1, true) then
        item.fn()
        ran = ran + 1
        io.write("ok - ", item.name, "\n")
    end
end

assert(ran > 0, "EDGE_FILTER selected no tests")
io.write(string.format("production edges passed: %d\n", ran))
