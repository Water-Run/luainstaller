--[[
Comprehensive smoke and audit runner for the luainstaller test samples.

Author:
    WaterRun
File:
    smoke_all.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local SOURCE_LOADER = [[
package.preload["luainstaller.analyzer"] = function() return dofile("src/analyzer.lua") end
package.preload["luainstaller.logger"] = function() return dofile("src/logger.lua") end
package.preload["luainstaller.manifest"] = function() return dofile("src/manifest.lua") end
package.preload["luainstaller.runtime"] = function() return dofile("src/runtime.lua") end
package.preload["luainstaller.cgen"] = function() return dofile("src/cgen.lua") end
package.preload["luainstaller"] = function() return dofile("src/init.lua") end
package.preload["luainstaller.cli"] = function() return assert(loadfile("src/cli.lua"))("luainstaller.cli") end
]]

local function run(command, opts)
    opts = opts or {}
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local out = pipe:read("*a")
    local ok = pipe:close()
    if opts.expect_failure then
        if ok then
            error("expected command to fail: " .. command .. "\n" .. out, 2)
        end
        return out
    end
    if not ok then
        error("command failed: " .. command .. "\n" .. out, 2)
    end
    return out
end

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected output to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
    end
end

local function assert_file_has_style_header(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a") or ""
    file:close()
    local header = content
    if header:sub(1, 2) == "#!" then
        header = header:match("^[^\n]*\n(.*)$") or ""
    end
    if header:sub(1, 4) ~= "--[[" then
        error("missing block header: " .. path, 2)
    end
    local first_block = header:match("^(%-%-%[%[.-%]%])") or ""
    for _, marker in ipairs({ "Author:", "File:", "Date:", "Updated:" }) do
        if not first_block:find(marker, 1, true) then
            error("missing " .. marker .. " in header: " .. path, 2)
        end
    end
    if #content > 0 and content:sub(-1) ~= "\n" then
        error("missing final newline: " .. path, 2)
    end
end

local function list_lua_files()
    local out = run("find test -type f -name '*.lua' | sort")
    local files = {}
    for line in out:gmatch("[^\n]+") do
        files[#files + 1] = line
    end
    return files
end

local function check_style()
    for _, path in ipairs(list_lua_files()) do
        assert_file_has_style_header(path)
    end
    local whitespace = run("rg -n '\\t|[ \\t]+$|\\r$' test || true")
    if whitespace ~= "" then
        error("whitespace style violations:\n" .. whitespace, 2)
    end
end

local function check_syntax()
    run("find test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p")
end

local function check_samples()
    run("for f in test/single_file/*.lua; do lua \"$f\" >/tmp/luainstaller-single.out 2>/tmp/luainstaller-single.err || { echo \"FAILED $f\"; cat /tmp/luainstaller-single.err; exit 1; }; done")
    run("lua test/student_management_system/smoke_test.lua")
    run("lua test/firebird_web_sql/smoke_test.lua")
    run("lua test/savinglua/smoke_test.lua")
    run("lua test/ltokei/smoke_test.lua")

    local missing = run("lua test/ltokei/main.lua /tmp/luainstaller-missing-path-for-smoke-all", {
        expect_failure = true,
    })
    assert_contains(missing, "does not exist")
end

local function check_analyzer_visibility()
    local script = [[
local analyzer = dofile("src/analyzer.lua")
local entries = {
    ["test/student_management_system/main.lua"] = { scripts = 5, libraries = 1 },
    ["test/firebird_web_sql/server.lua"] = { scripts_min = 17, libraries_min = 2 },
    ["test/savinglua/main.lua"] = { scripts = 1, libraries = 2 },
    ["test/ltokei/main.lua"] = { scripts = 3, libraries = 1 },
}
for entry, expect in pairs(entries) do
    local result = analyzer.analyzeDependencies(entry, { max_dependencies = 250 })
    if expect.scripts and #result.scripts ~= expect.scripts then
        error(entry .. " script count mismatch: " .. #result.scripts)
    end
    if expect.libraries and #result.libraries ~= expect.libraries then
        error(entry .. " library count mismatch: " .. #result.libraries)
    end
    if expect.scripts_min and #result.scripts < expect.scripts_min then
        error(entry .. " script count too low: " .. #result.scripts)
    end
    if expect.libraries_min and #result.libraries < expect.libraries_min then
        error(entry .. " library count too low: " .. #result.libraries)
    end
end
print("analyzer ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "analyzer ok")
end

local function check_api_contract()
    local script = SOURCE_LOADER .. [[
local luainstaller = require("luainstaller")

local function find_trace(items, requested)
    for _, item in ipairs(items) do
        if item.requested == requested then
            return item
        end
    end
    return nil
end

local analyzed = luainstaller.analyze({
    entry = "test/student_management_system/main.lua",
    max_deps = 250,
})
assert(analyzed.ok == true, analyzed.error and analyzed.error.message)
assert(analyzed.action == "analyze")
assert(type(analyzed.dependencies) == "table")
assert(#analyzed.dependencies.scripts == 5)
assert(#analyzed.dependencies.libraries == 1)

local manual = luainstaller.analyze({
    entry = "test/student_management_system/main.lua",
    depscan = false,
    include = { "test/student_management_system/model.lua" },
    exclude = { "model.lua" },
})
assert(manual.ok == true, manual.error and manual.error.message)
assert(#manual.dependencies.scripts == 0)

local traced = luainstaller.trace({
    entry = "test/student_management_system/main.lua",
    max_deps = 250,
})
assert(traced.ok == true, traced.error and traced.error.message)
assert(traced.action == "trace")
assert(type(traced.trace) == "table")
assert(#traced.trace > 0)

local model_trace = assert(find_trace(traced.trace, "model"))
assert(model_trace.requiring_file:match("student_management_system/main%.lua$"))
assert(type(model_trace.source_line) == "number")
assert(model_trace.classification == "lua")
assert(model_trace.selected_type == "lua")
assert(model_trace.selected_path:match("student_management_system/model%.lua$"))
assert(type(model_trace.candidates) == "table")
assert(#model_trace.candidates > 0)
assert(model_trace.reason == "resolved")

local firebird_trace = luainstaller.trace({
    entry = "test/firebird_web_sql/server.lua",
    max_deps = 250,
})
assert(firebird_trace.ok == true, firebird_trace.error and firebird_trace.error.message)
local optional_firebird = assert(find_trace(firebird_trace.trace, "luasql.firebird"))
assert(optional_firebird.optional == true)
assert(optional_firebird.classification == "missing")
assert(optional_firebird.reason == "optional-missing")
assert(type(optional_firebird.candidates) == "table")

local bundled = luainstaller.bundle({
    entry = "test/student_management_system/main.lua",
    mode = "onedir",
    out = "build/student-manager",
    max_deps = 250,
})
assert(bundled.ok == false)
assert(bundled.error.type == "NotImplementedError")
assert(type(bundled.error.manifest) == "table")
local manifest = bundled.error.manifest
assert(manifest.version == 1)
assert(manifest.output.mode == "onedir")
assert(manifest.entry.source_path:match("student_management_system/main%.lua$"))
assert(manifest.entry.destination_path:match("^%.luai/lua/"))
assert(type(manifest.lua.version) == "string")
assert(type(manifest.lua.abi) == "string")
assert(type(manifest.platform.os) == "string")
assert(type(manifest.platform.arch) == "string")
assert(manifest.launcher.profile == "shared-lua")
assert(#manifest.modules.lua == 5)
assert(#manifest.modules.native == 1)
assert(#manifest.trace > 0)
assert(manifest.hash_algorithm == "fnv1a32")
assert(type(manifest.modules.lua[1].content_hash) == "string")
assert(#manifest.compatibility >= 4)

local missing = luainstaller.analyze({ entry = "test/no-such-file.lua" })
assert(missing.ok == false)
assert(missing.error.type == "ScriptNotFoundError")

print("api contract ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "api contract ok")
end

local function cli_command(args)
    local quoted = {}
    for i = 1, #args do
        quoted[#quoted + 1] = string.format("%q", args[i])
    end
    return "lua -e " .. shell_quote(SOURCE_LOADER .. string.format([[
local cli = require("luainstaller.cli")
os.exit(cli.main({ %s }))
]], table.concat(quoted, ", ")))
end

local function check_cli_contract()
    local direct_help = run("lua src/cli.lua --help")
    assert_contains(direct_help, "luai -a <entry.lua>")

    local help = run(cli_command({ "--help" }))
    assert_contains(help, "luai -a <entry.lua>")
    assert_contains(help, "luai -t <entry.lua>")
    assert_contains(help, "luai -c <entry.lua>")

    local analyzed = run(cli_command({
        "-a",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
    }))
    assert_contains(analyzed, "success.")
    assert_contains(analyzed, "script(s)")
    assert_contains(analyzed, "library(ies)")

    local traced = run(cli_command({
        "-t",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
    }))
    assert_contains(traced, "trace.")
    assert_contains(traced, "resolved")

    local bundled = run(cli_command({
        "-c",
        "--onedir",
        "test/student_management_system/main.lua",
        "-o",
        "build/student-manager",
        "--max-deps",
        "250",
    }), {
        expect_failure = true,
    })
    assert_contains(bundled, "NotImplementedError")
    assert_contains(bundled, "onedir bundling is planned")

    print("cli contract ok")
end

local function check_runtime_cgen()
    local script = SOURCE_LOADER .. [[
local runtime = require("luainstaller.runtime")
local cgen = require("luainstaller.cgen")

local stripped = runtime.stripSource("\239\187\191#!/usr/bin/env lua\nprint('ok')")
assert(stripped == "print('ok')")

local previous_arg = _G.arg
_G.arg = { "outer" }
local payload = {
    entry = {
        id = "__entry__",
        path = "test/runtime_bundle/main.lua",
        source = "local greeter = require('greeter'); print(greeter.message(arg[1])); print('entry=' .. arg[0])",
    },
    modules = {
        greeter = {
            path = "test/runtime_bundle/greeter.lua",
            source = "return { message = function(name) return 'hello ' .. name end }",
        },
    },
}

local output = {}
local old_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    output[#output + 1] = table.concat(parts, "\t")
end

runtime.run(payload, { "direct" })
print = old_print
assert(_G.arg == previous_arg)
assert(output[1] == "hello direct")
assert(output[2] == "entry=test/runtime_bundle/main.lua")
_G.arg = previous_arg

local deps = {
    scripts = { "test/runtime_bundle/greeter.lua" },
    libraries = {},
}
local bootstrap = cgen.generateBootstrap({
    entry = "test/runtime_bundle/main.lua",
    dependencies = deps,
})
assert(type(bootstrap) == "string")
assert(bootstrap:find("luainstaller generated bootstrap", 1, true))

local chunk = assert(load(bootstrap, "@generated-runtime-bundle"))
local old_arg = _G.arg
_G.arg = { "generated.lua", "generated" }
local generated_output = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    generated_output[#generated_output + 1] = table.concat(parts, "\t")
end
chunk()
print = old_print
_G.arg = old_arg
assert(generated_output[1] == "hello generated")
assert(generated_output[2] == "entry=test/runtime_bundle/main.lua")

local single = cgen.generateBootstrap({
    entry = "test/single_file/01_hello_luainstaller.lua",
    dependencies = { scripts = {}, libraries = {} },
})
assert(assert(load(single, "@generated-single-file")))

print("runtime cgen ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "runtime cgen ok")
end

check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()
check_cli_contract()
check_runtime_cgen()

print("all packaging-target samples passed comprehensive smoke audit")
