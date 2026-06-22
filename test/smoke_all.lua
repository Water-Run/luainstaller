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
package.preload["luainstaller.compat"] = function() return dofile("src/compat.lua") end
package.preload["luainstaller.platform"] = function() return dofile("src/platform.lua") end
package.preload["luainstaller.runtime"] = function() return dofile("src/runtime.lua") end
package.preload["luainstaller.cgen"] = function() return dofile("src/cgen.lua") end
package.preload["luainstaller.launcher"] = function() return dofile("src/launcher.lua") end
package.preload["luainstaller.bundler"] = function() return dofile("src/bundler.lua") end
package.preload["luainstaller.require_engine"] = function() return dofile("src/require_engine.lua") end
package.preload["luainstaller.onefile"] = function() return dofile("src/onefile.lua") end
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

local function command_ok(command)
    local ok = os.execute(command .. " > /dev/null 2>&1")
    return ok == true or ok == 0
end

local function command_output(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local out = pipe:read("*a") or ""
    local ok = pipe:close()
    if not ok then
        error("command failed: " .. command .. "\n" .. out, 2)
    end
    return out
end

local function command_output_trimmed(command)
    local output = command_output(command)
    return (output:gsub("%s+$", ""))
end

local function remove_file(path)
    os.remove(path)
end

local function write_file(path, content)
    local handle = assert(io.open(path, "wb"))
    handle:write(content or "")
    handle:close()
end

local function read_file(path)
    local handle = assert(io.open(path, "rb"))
    local content = handle:read("*a") or ""
    handle:close()
    return content
end

local function remove_tree(path)
    if path and path ~= "" and path:match("^/tmp/luainstaller%-") then
        run("rm -rf " .. shell_quote(path))
    end
end

local function make_temp_dir(name)
    local path = "/tmp/luainstaller-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    remove_tree(path)
    run("mkdir -p " .. shell_quote(path))
    return path
end

local function current_lua_version()
    local version = run("lua -e " .. shell_quote("local v = _VERSION:match('(%d+%.%d+)'); assert(v); print(v)"))
    return (version:gsub("%s+$", ""))
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
    mode = "onefile",
    out = os.getenv("LUAI_API_ONEFILE_OUT"),
    max_deps = 250,
})
assert(bundled.ok == true, bundled.error and bundled.error.message)
assert(bundled.action == "bundle")
assert(bundled.mode == "onefile")
assert(type(bundled.executable) == "string")
local manifest = bundled.manifest
assert(manifest.version == 1)
assert(manifest.output.mode == "onefile")
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

local unsafe = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = ".",
    max_deps = 250,
})
assert(unsafe.ok == false)
assert(unsafe.error.type == "InvalidOutputError")

print("api contract ok")
]]
    local root = make_temp_dir("api-onefile")
    local onefile_out = root .. "/student-onefile"
    assert_contains(run("LUAI_API_ONEFILE_OUT=" .. shell_quote(onefile_out)
        .. " lua -e " .. shell_quote(script)), "api contract ok")
    remove_tree(root)
end

local function check_require_engines()
    local root = make_temp_dir("require-engine")
    write_file(root .. "/main.lua", [[
local name = arg[1] or "dynamic"
local mod = require(name)
print(mod.message())
]])
    write_file(root .. "/dynamic.lua", [[
return { message = function() return "runtime dynamic module" end }
]])

    local script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")

local manual = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    require_engine = "manual",
    include = { "test/runtime_bundle/greeter.lua" },
})
assert(manual.ok == true, manual.error and manual.error.message)
assert(#manual.dependencies.scripts == 1)
assert(manual.dependencies.scripts[1]:match("runtime_bundle/greeter%%.lua$"))

local runtime = luainstaller.analyze({
    entry = %q,
    require_engine = "runtime",
    run_args = { "dynamic" },
})
assert(runtime.ok == true, runtime.error and runtime.error.message)
assert(#runtime.dependencies.scripts == 1)
assert(runtime.dependencies.scripts[1]:match("dynamic%%.lua$"))
assert(#runtime.trace >= 1)
assert(runtime.trace[1].requested == "dynamic")

print("require engines ok")
]], root .. "/main.lua")

    assert_contains(run("lua -e " .. shell_quote(script)), "require engines ok")
    remove_tree(root)
end

local function check_compatibility_diagnostics()
    local script = SOURCE_LOADER .. [[
local luainstaller = require("luainstaller")

local traced = luainstaller.trace({
    entry = "test/runtime_bundle/main.lua",
    max_deps = 120,
})
assert(traced.ok == true, traced.error and traced.error.message)
assert(type(traced.compatibility) == "table")
assert(traced.compatibility.summary:match("same OS"))
assert(traced.compatibility.summary:match("same architecture"))
assert(traced.compatibility.summary:match("same ABI"))
assert(traced.compatibility.summary:match("same Lua ABI"))
assert(#traced.compatibility.notes >= 1)
assert(traced.compatibility.notes[1]:match("does not claim universal cross%-platform output"))
local diagnosed = luainstaller.compatibility({
    entry = "test/runtime_bundle/main.lua",
    max_deps = 120,
})
assert(diagnosed.ok == true, diagnosed.error and diagnosed.error.message)
assert(diagnosed.action == "compatibility")
assert(diagnosed.compatibility.summary == traced.compatibility.summary)
print("compat api ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "compat api ok")
end

local function check_manifest_without_popen()
    local script = SOURCE_LOADER .. [[
local manifest = require("luainstaller.manifest")
local saved_popen = io.popen
io.popen = nil
local built = manifest.build({
    entry = os.getenv("PWD") .. "/test/runtime_bundle/main.lua",
    dependencies = { scripts = {}, libraries = {} },
    mode = "onefile",
    out = "build/runtime",
})
io.popen = saved_popen
assert(built.ok == true, built.error and built.error.message)
assert(type(built.manifest.platform.os) == "string")
assert(type(built.manifest.platform.arch) == "string")
print("manifest no popen ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "manifest no popen ok")
end

local function check_bundler_without_popen()
    local out_dir = make_temp_dir("no-popen-bundler")
    remove_tree(out_dir)
    local script = SOURCE_LOADER .. string.format([[
local bundler = require("luainstaller.bundler")
local saved_popen = io.popen
io.popen = nil
local result = bundler.bundleOnedir({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    dependencies = { scripts = {}, libraries = {} },
    trace = {},
    manifest = {
        version = 1,
        launcher = { profile = "shared-lua" },
        modules = { lua = {}, native = {}, external = {} },
    },
})
io.popen = saved_popen
assert(result.ok == false)
assert(result.error.type == "ToolchainError")
print("bundler no popen ok")
]], out_dir)
    assert_contains(run("lua -e " .. shell_quote(script)), "bundler no popen ok")
    remove_tree(out_dir)
end

local function check_platform_profiles()
    local script = SOURCE_LOADER .. [[
local platform = require("luainstaller.platform")
local host = platform.detectHost()
assert(host.os == "linux" or host.os == "macos" or host.os == "windows" or host.os == "unknown")
assert(type(host.arch) == "string")

local linux = platform.profile({ target_os = "linux" })
assert(linux.executable_suffix == "")
assert(linux.native_extensions[1] == ".so")
assert(linux.loader_rpath == "$ORIGIN/.luai/native")

local macos = platform.profile({ target_os = "macos", lua_prefix = "/tmp/lua" })
assert(macos.executable_suffix == "")
assert(macos.native_extensions[1] == ".so")
assert(macos.native_extensions[2] == ".dylib")
assert(macos.loader_rpath == "@loader_path/.luai/native")
assert(macos.lua_prefix == "/tmp/lua")

local windows = platform.profile({ target_os = "windows" })
assert(windows.executable_suffix == ".exe")
assert(windows.native_extensions[1] == ".dll")
assert(windows.loader_rpath == nil)
print("platform profiles ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "platform profiles ok")
end

local function check_macos_profile_reaches_toolchain()
    local script = SOURCE_LOADER .. [[
local bundler = require("luainstaller.bundler")
local result = bundler.bundleOnedir({
    entry = "test/runtime_bundle/main.lua",
    out = "/tmp/luainstaller-macos-profile-smoke",
    target_os = "macos",
    lua_prefix = "/tmp/luainstaller-missing-lua-prefix",
    dependencies = { scripts = {}, libraries = {} },
    trace = {},
    manifest = {
        version = 1,
        launcher = { profile = "shared-lua" },
        modules = { lua = {}, native = {}, external = {} },
    },
})
assert(result.ok == false)
assert(result.error.type == "ToolchainError")
assert(tostring(result.error.message):find("Lua prefix", 1, true))
print("macos profile toolchain ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "macos profile toolchain ok")
end

local function check_windows_profile_reaches_toolchain()
    local script = SOURCE_LOADER .. [[
local bundler = require("luainstaller.bundler")
local result = bundler.bundleOnedir({
    entry = "test/runtime_bundle/main.lua",
    out = "/tmp/luainstaller-windows-profile-smoke",
    target_os = "windows",
    lua_prefix = "/tmp/luainstaller-missing-windows-lua-prefix",
    dependencies = { scripts = {}, libraries = {} },
    trace = {},
    manifest = {
        version = 1,
        launcher = { profile = "shared-lua" },
        modules = { lua = {}, native = {}, external = {} },
    },
})
assert(result.ok == false)
assert(result.error.type == "ToolchainError")
assert(tostring(result.error.message):find("Windows Lua prefix", 1, true))
print("windows profile toolchain ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "windows profile toolchain ok")
end

local function check_remote_onefile_script_coverage()
    local macos = read_file("tools/remote-test-macos.sh")
    assert_contains(macos, "bundle_onefile()")
    assert_contains(macos, "--onefile")
    assert_contains(macos, "mac-onefile-runtime")
    assert_contains(macos, "mac-onefile-student")

    local windows = read_file("tools/remote-test-windows.sh")
    assert_contains(windows, "bundle_demo_onefile()")
    assert_contains(windows, "--onefile")
    assert_contains(windows, "runtime-onefile.exe")
    assert_contains(windows, "student-onefile.exe")
    print("remote onefile script coverage ok")
end

local function check_release_safety_contract()
    local root = make_temp_dir("release-safety")
    local unsafe_out = root .. "/unsafe-existing"
    run("mkdir -p " .. shell_quote(unsafe_out))
    write_file(unsafe_out .. "/sentinel.txt", "user data")

    local script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")

local unsafe_onedir = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    max_deps = 120,
})
assert(unsafe_onedir.ok == false, "non-empty existing onedir output must be rejected")
assert(unsafe_onedir.error.type == "InvalidOutputError")

local unsafe_onefile = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    mode = "onefile",
    out = %q,
    max_deps = 120,
})
assert(unsafe_onefile.ok == false, "existing directory onefile output must be rejected")
assert(unsafe_onefile.error.type == "InvalidOutputError")

print("output safety ok")
]], unsafe_out, root .. "/onefile-dir")
    run("mkdir -p " .. shell_quote(root .. "/onefile-dir"))
    assert_contains(run("lua -e " .. shell_quote(script)), "output safety ok")
    assert(read_file(unsafe_out .. "/sentinel.txt") == "user data")

    local forged_out = root .. "/forged-generated"
    run("mkdir -p " .. shell_quote(forged_out .. "/.luai"))
    write_file(forged_out .. "/.luai/manifest.lua", "-- generated by luainstaller\nreturn {}\n")
    write_file(forged_out .. "/sentinel.txt", "user data")
    local forged_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local forged = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    max_deps = 120,
})
assert(forged.ok == false, "forged generated manifest must not authorize deleting user files")
assert(forged.error.type == "InvalidOutputError")
print("forged manifest safety ok")
]], forged_out)
    assert_contains(run("lua -e " .. shell_quote(forged_script)), "forged manifest safety ok")
    assert(read_file(forged_out .. "/sentinel.txt") == "user data")

    local pkg_root = root .. "/init-packages"
    run("mkdir -p " .. shell_quote(pkg_root .. "/a") .. " " .. shell_quote(pkg_root .. "/b"))
    write_file(pkg_root .. "/main.lua", [[
local a = require("a")
local b = require("b")
print(a.name .. ":" .. b.name)
]])
    write_file(pkg_root .. "/a/init.lua", [[
return { name = "a" }
]])
    write_file(pkg_root .. "/b/init.lua", [[
return { name = "b" }
]])

    local pkg_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local result = luainstaller.bundle({
    entry = %q,
    out = %q,
    max_deps = 120,
})
assert(result.ok == true, result.error and result.error.message)
local destinations = {}
for _, item in ipairs(result.manifest.modules.lua) do
    destinations[item.destination_path] = true
end
assert(destinations[".luai/lua/a/init.lua"])
assert(destinations[".luai/lua/b/init.lua"])
print(result.executable)
]], pkg_root .. "/main.lua", root .. "/init-package-out")
    local bundled = run("lua -e " .. shell_quote(pkg_script))
    local exe = bundled:match("([^\r\n]+)%s*$")
    assert_contains(run(shell_quote(exe)), "a:b")

    local windows_script = read_file("tools/remote-test-windows.sh")
    if windows_script:find("2288", 1, true) then
        error("remote Windows test script must not contain a default password", 2)
    end
    if windows_script:find("WINDOWS_PASSWORD=${WINDOWS_PASSWORD:-", 1, true) then
        error("remote Windows password must be required from the environment", 2)
    end
    assert_contains(windows_script, "SSH_OPTS=${SSH_OPTS:-")
    assert_contains(windows_script, "StrictHostKeyChecking=no")
    assert_contains(windows_script, "sshpass -e scp $SSH_OPTS")
    assert_contains(windows_script, "sshpass -e ssh $SSH_OPTS")

    local test_readme = read_file("test/README.md")
    assert_contains(test_readme, "WINDOWS_PASSWORD=...")
    assert_contains(test_readme, "tools/remote-test-windows.sh")

    local test_matrix = read_file("docs/CROSS-PLATFORM-TEST-MATRIX.md")
    assert_contains(test_matrix, "WINDOWS_PASSWORD=...")
    assert_contains(test_matrix, "tools/remote-test-windows.sh")

    remove_tree(root)
    print("release safety contract ok")
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
    assert_contains(traced, "compatibility.")
    assert_contains(traced, "same OS, same architecture, same ABI, same Lua ABI")
    assert_contains(traced, "does not claim universal cross-platform output")

    local verbose_analyzed = run(cli_command({
        "-a",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
        "--verbose",
    }))
    assert_contains(verbose_analyzed, "trace records:")
    assert_contains(verbose_analyzed, "model")

    local engines = run(cli_command({ "engines" }))
    assert_contains(engines, "Legacy engine names")
    assert_contains(engines, "current bundler ignores -engine")

    local cli_out = make_temp_dir("cli-onedir")
    local bundled = run(cli_command({
        "-c",
        "--onedir",
        "test/student_management_system/main.lua",
        "-o",
        cli_out,
        "--max-deps",
        "250",
    }))
    assert_contains(bundled, "success.")
    assert_contains(bundled, cli_out .. "/")
    remove_tree(cli_out)

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
local outer_arg = _G.arg
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
assert(_G.arg == outer_arg)
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
_G.arg = { [0] = "generated.lua", "generated" }
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

local function check_c_launcher()
    local script = SOURCE_LOADER .. [[
local launcher = require("luainstaller.launcher")
local c_source = launcher.generateSource({
    entry = "test/runtime_bundle/main.lua",
    dependencies = {
        scripts = { "test/runtime_bundle/greeter.lua" },
        libraries = {},
    },
})

assert(c_source:match("static const unsigned char luai_bootstrap%[%]"))
assert(c_source:match("static const size_t luai_bootstrap_size"))
assert(c_source:match("luaL_newstate"))

local handle = assert(io.open("test/runtime_bundle/generated_launcher.c", "wb"))
handle:write(c_source)
handle:close()
print("c source generated")
]]

    assert_contains(run("lua -e " .. shell_quote(script)), "c source generated")

    if not command_ok("cc --version") or not command_ok("pkg-config --exists lua") then
        remove_file("test/runtime_bundle/generated_launcher.c")
        print("c launcher compile skipped")
        return
    end

    local c_path = "test/runtime_bundle/generated_launcher.c"
    local exe_path = "test/runtime_bundle/generated_launcher"
    remove_file(exe_path)

    local compile = string.format(
        "cc %s -o %s %s",
        shell_quote(c_path),
        shell_quote(exe_path),
        "$(pkg-config --cflags --libs lua)"
    )
    local ok = os.execute(compile)
    assert(ok == true or ok == 0, "generated C launcher should compile")

    local output = run(shell_quote(exe_path) .. " launcher")
    assert_contains(output, "hello launcher")
    assert_contains(output, "entry=test/runtime_bundle/main.lua")

    remove_file(c_path)
    remove_file(exe_path)
    print("c launcher ok")
end

local function check_onedir_bundles()
    local script = SOURCE_LOADER .. [[
local luainstaller = require("luainstaller")

local function assert_bundle(opts)
    local result = luainstaller.bundle(opts)
    assert(result.ok == true, result.error and result.error.message)
    assert(result.action == "bundle")
    assert(result.mode == "onedir")
    assert(type(result.executable) == "string")
    assert(type(result.manifest) == "table")
    print(result.executable)
end

assert_bundle({
    entry = "test/runtime_bundle/main.lua",
    out = os.getenv("LUAI_RUNTIME_OUT"),
    max_deps = 250,
})
assert_bundle({
    entry = "test/student_management_system/main.lua",
    out = os.getenv("LUAI_STUDENT_OUT"),
    max_deps = 250,
})
assert_bundle({
    entry = "test/savinglua/main.lua",
    out = os.getenv("LUAI_SAVINGLUA_OUT"),
    max_deps = 250,
})
assert_bundle({
    entry = "test/firebird_web_sql/server.lua",
    out = os.getenv("LUAI_FIREBIRD_OUT"),
    max_deps = 250,
})
]]

    local root = make_temp_dir("onedir")
    local runtime_out = root .. "/runtime"
    local student_out = root .. "/student"
    local savinglua_out = root .. "/savinglua"
    local firebird_out = root .. "/firebird-web-sql"
    local env = table.concat({
        "LUAI_RUNTIME_OUT=" .. shell_quote(runtime_out),
        "LUAI_STUDENT_OUT=" .. shell_quote(student_out),
        "LUAI_SAVINGLUA_OUT=" .. shell_quote(savinglua_out),
        "LUAI_FIREBIRD_OUT=" .. shell_quote(firebird_out),
    }, " ")

    run(env .. " lua -e " .. shell_quote(script))

    local runtime_liblua = run("find " .. shell_quote(runtime_out .. "/.luai/native") .. " -maxdepth 1 -type f -name 'liblua*.so*' | sort")
    assert_contains(runtime_liblua, "liblua")
    local manifest = assert(loadfile(runtime_out .. "/.luai/manifest.lua"))()
    assert(type(manifest.launcher.lua_runtime) == "table")
    assert(manifest.launcher.lua_runtime.destination_path:match("^%.luai/native/liblua"))
    if command_ok("readelf --version") then
        local dynamic = command_output("readelf -d " .. shell_quote(runtime_out .. "/runtime"))
        assert_contains(dynamic, "$ORIGIN/.luai/native")
    end

    assert_contains(run(shell_quote(runtime_out .. "/runtime") .. " onedir"), "hello onedir")

    local student_data = root .. "/students.json"
    assert_contains(run(shell_quote(student_out .. "/student") .. " --data " .. shell_quote(student_data) .. " seed"), "Seeded 8 students")
    assert_contains(run(shell_quote(student_out .. "/student") .. " --data " .. shell_quote(student_data) .. " list --sort average"), "Ada Lovelace")

    local savinglua_db = root .. "/savinglua.sqlite3"
    assert_contains(run(shell_quote(savinglua_out .. "/savinglua") .. " --db " .. shell_quote(savinglua_db) .. " put users:ada '{\"name\":\"Ada Lovelace\",\"score\":98}'"), "stored users:ada")
    assert_contains(run(shell_quote(savinglua_out .. "/savinglua") .. " --db " .. shell_quote(savinglua_db) .. " get users:ada"), "Ada Lovelace")

    if command_ok("curl --version") then
        local port = "19091"
        local server_smoke = table.concat({
            "set -e",
            "EXE=" .. shell_quote(firebird_out .. "/firebird-web-sql"),
            "LOG=" .. shell_quote(root .. "/firebird.log"),
            "FIREBIRD_WEB_SQL_PORT=" .. port .. " FIREBIRD_WEB_SQL_TOKEN=testtoken \"$EXE\" >\"$LOG\" 2>&1 &",
            "PID=$!",
            "cleanup() { kill \"$PID\" >/dev/null 2>&1 || true; wait \"$PID\" >/dev/null 2>&1 || true; }",
            "trap cleanup EXIT",
            "for i in $(seq 1 30); do",
            "  if curl -fsS http://127.0.0.1:" .. port .. "/api/status -H 'X-Auth-Token: testtoken' | rg '\"ok\":true' >/dev/null; then exit 0; fi",
            "  sleep 0.2",
            "  if ! kill -0 \"$PID\" >/dev/null 2>&1; then cat \"$LOG\"; exit 1; fi",
            "done",
            "cat \"$LOG\"",
            "exit 1",
        }, "\n")
        run("bash -c " .. shell_quote(server_smoke))
    end

    remove_tree(root)
    print("onedir bundles ok")
end

local function check_onefile_bundles()
    local script = SOURCE_LOADER .. [[
local luainstaller = require("luainstaller")

local function assert_bundle(opts)
    local result = luainstaller.bundle(opts)
    assert(result.ok == true, result.error and result.error.message)
    assert(result.action == "bundle")
    assert(result.mode == "onefile")
    assert(type(result.executable) == "string")
    print(result.executable)
end

assert_bundle({
    entry = "test/runtime_bundle/main.lua",
    mode = "onefile",
    out = os.getenv("LUAI_RUNTIME_ONEFILE_OUT"),
    max_deps = 250,
})
assert_bundle({
    entry = "test/student_management_system/main.lua",
    mode = "onefile",
    out = os.getenv("LUAI_STUDENT_ONEFILE_OUT"),
    max_deps = 250,
})
]]

    local root = make_temp_dir("onefile")
    local runtime_out = root .. "/runtime-onefile"
    local student_out = root .. "/student-onefile"
    local built = run("LUAI_RUNTIME_ONEFILE_OUT=" .. shell_quote(runtime_out)
        .. " LUAI_STUDENT_ONEFILE_OUT=" .. shell_quote(student_out)
        .. " lua -e " .. shell_quote(script))
    assert_contains(built, runtime_out)
    assert_contains(built, student_out)
    local cache_root = root .. "/onefile-cache"
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile"), "hello onefile")
    local manifest_path = command_output_trimmed("find " .. shell_quote(cache_root) .. " -path '*/.luai/manifest.lua' | sort | head -n 1")
    if manifest_path == "" then
        error("onefile cache manifest was not extracted", 2)
    end
    local first_mtime = command_output_trimmed("stat -c %Y " .. shell_quote(manifest_path))
    run("sleep 1")
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile-again"), "hello onefile-again")
    local second_mtime = command_output_trimmed("stat -c %Y " .. shell_quote(manifest_path))
    if first_mtime ~= second_mtime then
        error("onefile cache rewrote matching extracted file", 2)
    end
    local inner_path = command_output_trimmed("find " .. shell_quote(cache_root) .. " -type f -perm /111 -name inner | sort | head -n 1")
    if inner_path == "" then
        error("onefile cache inner executable was not found", 2)
    end
    run("chmod -x " .. shell_quote(inner_path))
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile-permission"), "hello onefile-permission")
    local symlink_target = root .. "/onefile-symlink-target.txt"
    write_file(symlink_target, "do not overwrite")
    run("rm -f " .. shell_quote(manifest_path))
    run("ln -s " .. shell_quote(symlink_target) .. " " .. shell_quote(manifest_path))
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile-symlink"), "hello onefile-symlink")
    assert(read_file(symlink_target) == "do not overwrite", "onefile extraction must not write through symlinks")
    local link_state = command_output_trimmed("test ! -L " .. shell_quote(manifest_path) .. " && echo regular")
    assert(link_state == "regular")
    local student_data = root .. "/students-onefile.json"
    assert_contains(run(shell_quote(student_out) .. " --data " .. shell_quote(student_data) .. " seed"), "Seeded 8 students")
    assert_contains(run(shell_quote(student_out) .. " --data " .. shell_quote(student_data) .. " list --sort average"), "Ada Lovelace")
    remove_tree(root)
    print("onefile bundles ok")
end

local function check_cli_require_engine_runtime()
    local root = make_temp_dir("cli-require-engine")
    write_file(root .. "/main.lua", [[
local name = arg[1] or "dynamic"
local mod = require(name)
print(mod.message())
]])
    write_file(root .. "/dynamic.lua", [[
return { message = function() return "cli runtime dynamic module" end }
]])

    local traced = run(cli_command({
        "-a",
        root .. "/main.lua",
        "--require-engine",
        "runtime",
        "--",
        "dynamic",
    }))
    assert_contains(traced, "success.")
    assert_contains(traced, "dynamic.lua")
    remove_tree(root)
    print("cli require engine ok")
end

local function check_installed_cli_bundle()
    if not command_ok("luarocks --version") then
        print("installed cli bundle skipped: luarocks unavailable")
        return
    end

    local root = make_temp_dir("installed-cli")
    local tree = root .. "/tree"
    local out_dir = root .. "/runtime"
    run("luarocks make --tree " .. shell_quote(tree) .. " luainstaller-1.0.0-1.rockspec")
    run("cd /tmp && " .. shell_quote(tree .. "/bin/luai") .. " -c --onedir "
        .. shell_quote(os.getenv("PWD") .. "/test/runtime_bundle/main.lua")
        .. " -o " .. shell_quote(out_dir) .. " --max-deps 120")
    assert_contains(run(shell_quote(out_dir .. "/runtime") .. " installed"), "hello installed")
    remove_tree(root)
    print("installed cli bundle ok")
end

local function check_source_install_bundle()
    local root = make_temp_dir("source-install")
    local prefix = root .. "/prefix"
    local out_dir = root .. "/runtime"
    run("sh tools/install-source.sh --prefix " .. shell_quote(prefix))
    assert_contains(run(shell_quote(prefix .. "/bin/luai") .. " --version"), "Version 1.0.0")
    run("cd /tmp && " .. shell_quote(prefix .. "/bin/luai") .. " -c --onedir "
        .. shell_quote(os.getenv("PWD") .. "/test/runtime_bundle/main.lua")
        .. " -o " .. shell_quote(out_dir) .. " --max-deps 120")
    assert_contains(run(shell_quote(out_dir .. "/runtime") .. " source-install"), "hello source-install")
    local lua_version = current_lua_version()
    run("LUA_PATH=" .. shell_quote(prefix .. "/share/lua/" .. lua_version .. "/?.lua;"
        .. prefix .. "/share/lua/" .. lua_version .. "/?/init.lua;;")
        .. " lua -e 'local launcher = require(\"luainstaller.launcher\"); assert(type(launcher.generateSource) == \"function\")'")
    remove_tree(root)
    print("source install bundle ok")
end

check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()
check_require_engines()
check_compatibility_diagnostics()
check_manifest_without_popen()
check_bundler_without_popen()
check_platform_profiles()
check_macos_profile_reaches_toolchain()
check_windows_profile_reaches_toolchain()
check_remote_onefile_script_coverage()
check_release_safety_contract()
check_cli_contract()
check_runtime_cgen()
check_c_launcher()
check_onedir_bundles()
check_onefile_bundles()
check_cli_require_engine_runtime()
check_installed_cli_bundle()
check_source_install_bundle()

print("all packaging-target samples passed comprehensive smoke audit")
