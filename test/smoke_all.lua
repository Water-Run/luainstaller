--[[
Comprehensive smoke and audit runner for the luainstaller test samples.

Author:
    WaterRun
File:
    smoke_all.lua
Date:
    2026-06-14
Updated:
    2026-07-11
]]

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local SOURCE_LOADER = [[
package.preload["luainstaller.fs"] = function() return dofile("src/fs.lua") end
package.preload["luainstaller.hash"] = function() return dofile("src/hash.lua") end
package.preload["luainstaller.analyzer"] = function() return dofile("src/analyzer.lua") end
package.preload["luainstaller.logger"] = function() return dofile("src/logger.lua") end
package.preload["luainstaller.manifest"] = function() return dofile("src/manifest.lua") end
package.preload["luainstaller.compat"] = function() return dofile("src/compat.lua") end
package.preload["luainstaller.process"] = function() return dofile("src/process.lua") end
package.preload["luainstaller.toolchain"] = function() return dofile("src/toolchain.lua") end
package.preload["luainstaller.path"] = function() return dofile("src/path.lua") end
package.preload["luainstaller.result"] = function() return dofile("src/result.lua") end
package.preload["luainstaller.platform"] = function() return dofile("src/platform.lua") end
package.preload["luainstaller.runtime"] = function() return dofile("src/runtime.lua") end
package.preload["luainstaller.cgen"] = function() return dofile("src/cgen.lua") end
package.preload["luainstaller.launcher"] = function() return dofile("src/launcher.lua") end
package.preload["luainstaller.bundler"] = function() return dofile("src/bundler.lua") end
package.preload["luainstaller.discovery"] = function() return dofile("src/discovery.lua") end
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

local function host_system()
    return command_output_trimmed("uname -s")
end

local function file_mtime(path)
    if host_system() == "Darwin" then
        return command_output_trimmed("stat -f %m " .. shell_quote(path))
    end
    return command_output_trimmed("stat -c %Y " .. shell_quote(path))
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

local function assert_file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then
        error("expected file to exist: " .. path, 2)
    end
    handle:close()
end

local function file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then
        return false
    end
    handle:close()
    return true
end

local function remove_tree(path)
    if path and path ~= "" and path:match("^/tmp/luainstaller%-") then
        run("rm -rf " .. shell_quote(path))
    end
end

local function make_temp_dir(name)
    local path = "/tmp/luainstaller-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    remove_tree(path)
    run("mkdir -m 700 " .. shell_quote(path))
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

local function assert_not_contains(text, pattern)
    if tostring(text):find(pattern, 1, true) then
        error("expected output not to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
    end
end

local function assert_equals(actual, expected)
    if actual ~= expected then
        error("expected:\n" .. tostring(expected) .. "\nactual:\n" .. tostring(actual), 2)
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
    local out = run("find src test -type f -name '*.lua' | sort")
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
    local paths = run("find src test -type f | sort")
    for path in paths:gmatch("[^\n]+") do
        local content = read_file(path)
        if not content:find("\0", 1, true) then
            local position = content:find("\t", 1, true)
                or content:find("\r", 1, true)
                or content:find("[ ]+\n")
                or content:find("[ ]+$")
            if position then
                local _, line_count = content:sub(1, position):gsub("\n", "")
                error(string.format("whitespace style violation: %s:%d", path, line_count + 1), 2)
            end
        end
    end
end

local function check_syntax()
    run("find src test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p")
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
    local script = SOURCE_LOADER .. [[
local analyzer = require("luainstaller.analyzer")
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

assert(luainstaller.getEngines == nil)
assert(luainstaller.ErrorTypes.REQUIRE_ENGINE == nil)
assert(luainstaller.ErrorTypes.DISCOVERY == "DiscoveryError")
assert(luainstaller.ErrorTypes.LAUNCHER_GENERATION == "LauncherGenerationError")
assert(luainstaller.build == nil)
assert(luainstaller.bundleToSinglefile == nil)

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
assert(manifest.version == 2)
assert(manifest.output.mode == "onefile")
assert(manifest.entry.source_path:match("student_management_system/main%.lua$"))
assert(manifest.entry.destination_path:match("^%.luai/lua/"))
assert(type(manifest.lua.version) == "string")
assert(type(manifest.lua.abi) == "string")
assert(type(manifest.platform.host.os) == "string")
assert(type(manifest.platform.host.arch) == "string")
assert(type(manifest.platform.target.os) == "string")
assert(type(manifest.platform.target.arch) == "string")
local expected_profiles = {
    linux = "shared-lua",
    macos = "static-lua",
    windows = "windows-shared-lua",
}
assert(manifest.launcher.profile == expected_profiles[manifest.platform.target.os])
assert(#manifest.modules.lua == 5)
assert(#manifest.modules.native == 1)
assert(#manifest.trace > 0)
assert(manifest.hash_algorithm == "sha256")
assert(type(manifest.modules.lua[1].content_hash) == "string")
assert(#manifest.modules.lua[1].content_hash == 64)
assert(#manifest.compatibility >= 4)

local missing = luainstaller.analyze({ entry = "test/no-such-file.lua" })
assert(missing.ok == false)
assert(missing.error.type == "ScriptNotFoundError")

local non_table = luainstaller.analyze("test/runtime_bundle/main.lua")
assert(non_table.ok == false)
assert(non_table.error.type == "InvalidOptionsError")

local old_option = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    require_engine = "runtime",
})
assert(old_option.ok == false)
assert(old_option.error.type == "InvalidOptionsError")
assert(old_option.error.option == "require_engine")

local invalid_include = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    include = "test/runtime_bundle/greeter.lua",
})
assert(invalid_include.ok == false)
assert(invalid_include.error.type == "InvalidOptionsError")
assert(invalid_include.error.option == "include")

local invalid_run_args = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    discovery_mode = "runtime",
    run_args = "dynamic",
})
assert(invalid_run_args.ok == false)
assert(invalid_run_args.error.type == "InvalidOptionsError")
assert(invalid_run_args.error.option == "run_args")

local invalid_max_deps = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    max_deps = "abc",
})
assert(invalid_max_deps.ok == false)
assert(invalid_max_deps.error.type == "InvalidOptionsError")
assert(invalid_max_deps.error.option == "max_deps")

local unsafe = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = ".",
    max_deps = 250,
})
assert(unsafe.ok == false)
assert(unsafe.error.type == "InvalidOutputError")

assert(luainstaller.clearLogs() == true)
local logged_missing = luainstaller.analyze({ entry = "test/no-such-file.lua" })
assert(logged_missing.ok == false)
local error_logs = luainstaller.getLogs({
    level = luainstaller.LogLevel.ERROR,
    action = "analyze",
})
assert(#error_logs >= 1, "failed API operation must be recorded in logs")
assert(error_logs[1].details.error_type == "ScriptNotFoundError")

print("api contract ok")
]]
    local root = make_temp_dir("api-onefile")
    local onefile_out = root .. "/student-onefile"
    assert_contains(run("HOME=" .. shell_quote(root .. "/home")
        .. " LUAI_API_ONEFILE_OUT=" .. shell_quote(onefile_out)
        .. " lua -e " .. shell_quote(script)), "api contract ok")
    remove_tree(root)
end

local function check_discovery_modes()
    local root = make_temp_dir("discovery-mode")
    write_file(root .. "/main.lua", [[
local name = arg[1] or "dynamic"
local mod = require(name)
print(mod.message())
]])
    write_file(root .. "/dynamic.lua", [[
return { message = function() return "runtime dynamic module" end }
]])
    write_file(root .. "/optional.lua", [[
local ok = pcall(require, "luainstaller_optional_module_that_does_not_exist")
assert(not ok)
print("optional module absent")
]])

    local script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")

local manual = luainstaller.analyze({
    entry = "test/runtime_bundle/main.lua",
    discovery_mode = "manual",
    include = { "test/runtime_bundle/greeter.lua" },
})
assert(manual.ok == true, manual.error and manual.error.message)
assert(#manual.dependencies.scripts == 1)
assert(manual.dependencies.scripts[1]:match("runtime_bundle/greeter%%.lua$"))

local runtime = luainstaller.analyze({
    entry = %q,
    discovery_mode = "runtime",
    run_args = { "dynamic" },
})
assert(runtime.ok == true, runtime.error and runtime.error.message)
assert(#runtime.dependencies.scripts == 1)
assert(runtime.dependencies.scripts[1]:match("dynamic%%.lua$"))
assert(#runtime.trace >= 1)
assert(runtime.trace[1].requested == "dynamic")

local optional = luainstaller.analyze({
    entry = %q,
    discovery_mode = "runtime",
})
assert(optional.ok == true, optional.error and optional.error.message)
assert(#optional.dependencies.scripts == 0)
assert(#optional.dependencies.libraries == 0)

print("discovery modes ok")
]], root .. "/main.lua", root .. "/optional.lua")

    assert_contains(run("lua -e " .. shell_quote(script)), "discovery modes ok")
    remove_tree(root)
end

local function check_dependency_edge_cases()
    local root = make_temp_dir("dependency-edges")
    run("mkdir -p " .. shell_quote(root .. "/manual/foo") .. " " .. shell_quote(root .. "/fakebin")
        .. " " .. shell_quote(root .. "/native") .. " " .. shell_quote(root .. "/builtin")
        .. " " .. shell_quote(root .. "/dynamic") .. " " .. shell_quote(root .. "/lexer")
        .. " " .. shell_quote(root .. "/escaped/escaped")
        .. " " .. shell_quote(root .. "/local-require"))

    write_file(root .. "/manual/main.lua", [[
local mod = require("foo.bar")
print(mod.message())
]])
    write_file(root .. "/manual/foo/bar.lua", [[
return { message = function() return "manual include nested ok" end }
]])

    write_file(root .. "/native/main.lua", [[
local mod = require("fake_native")
print(mod)
]])
    write_file(root .. "/native/fake_native.a", "not a loadable lua native module")

    write_file(root .. "/builtin/main.lua", [[
local mod = require("arg")
print(mod.value)
]])
    write_file(root .. "/builtin/arg.lua", [[
return { value = "local arg module" }
]])

    write_file(root .. "/dynamic/main.lua", [[
local suffix = "module"
pcall(require, "dynamic_" .. suffix)
]])

    write_file(root .. "/lexer/main.lua", [[
local value = require.foo
print(type(value))
]])

    write_file(root .. "/escaped/main.lua", [[
local value = require("escaped\046name")
print(value.message)
]])
    write_file(root .. "/escaped/escaped/name.lua", [[
return { message = "escaped module name ok" }
]])

    write_file(root .. "/local-require/main.lua", [[
local require =
    require
local value = require("dependency")
print(value.message)
]])
    write_file(root .. "/local-require/dependency.lua", [[
return { message = "local require ok" }
]])

    write_file(root .. "/fakebin/lua", [[
#!/bin/sh
echo fake lua should not run >&2
exit 37
]])
    run("chmod +x " .. shell_quote(root .. "/fakebin/lua"))
    write_file(root .. "/runtime_main.lua", [[
local mod = require(arg[1])
print(mod.message())
]])
    write_file(root .. "/runtime_dep.lua", [[
return { message = function() return "runtime interpreter ok" end }
]])

    local lua_bin = command_output_trimmed("command -v lua")
    local script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")

local manual = luainstaller.bundle({
    entry = %q,
    discovery_mode = "manual",
    include = { %q },
    out = %q,
    max_deps = 20,
})
assert(manual.ok == true, manual.error and manual.error.message)
local handle = assert(io.popen(%q .. " 2>&1", "r"))
local output = handle:read("*a") or ""
local ok = handle:close()
assert(ok == true or ok == 0, output)
assert(output:find("manual include nested ok", 1, true), output)

local native = luainstaller.analyze({
    entry = %q,
    max_deps = 20,
})
assert(native.ok == false, "static .a archives must not be accepted as loadable native modules")
assert(native.error.type == "ModuleNotFoundError")

local builtin = luainstaller.trace({
    entry = %q,
    max_deps = 20,
})
assert(builtin.ok == true, builtin.error and builtin.error.message)
local found_arg = false
for _, item in ipairs(builtin.trace) do
    if item.requested == "arg" and item.selected_path and item.selected_path:match("builtin/arg%%.lua$") then
        found_arg = true
    end
end
assert(found_arg, "local arg.lua must not be treated as a builtin module")

local dynamic = luainstaller.analyze({
    entry = %q,
    max_deps = 20,
})
assert(dynamic.ok == false, "dynamic pcall(require, ...) must be reported")
assert(dynamic.error.type == "DynamicRequireError")

local lexer = luainstaller.analyze({
    entry = %q,
    max_deps = 20,
})
assert(lexer.ok == true, lexer.error and lexer.error.message)

local escaped = luainstaller.analyze({
    entry = %q,
    max_deps = 20,
})
assert(escaped.ok == true, escaped.error and escaped.error.message)
assert(#escaped.dependencies.scripts == 1)
assert(escaped.dependencies.scripts[1]:match("escaped/name%%.lua$"))

local local_require = luainstaller.analyze({
    entry = %q,
    max_deps = 20,
})
assert(local_require.ok == true, local_require.error and local_require.error.message)
assert(#local_require.dependencies.scripts == 1)
assert(local_require.dependencies.scripts[1]:match("local%%-require/dependency%%.lua$"))

local runtime = luainstaller.analyze({
    entry = %q,
    discovery_mode = "runtime",
    run_args = { "runtime_dep" },
    max_deps = 20,
})
assert(runtime.ok == true, runtime.error and runtime.error.message)
assert(#runtime.dependencies.scripts == 1)
assert(runtime.dependencies.scripts[1]:match("runtime_dep%%.lua$"))

print("dependency edge cases ok")
]], root .. "/manual/main.lua", root .. "/manual/foo/bar.lua", root .. "/manual/out",
        shell_quote(root .. "/manual/out/out"), root .. "/native/main.lua", root .. "/builtin/main.lua",
        root .. "/dynamic/main.lua", root .. "/lexer/main.lua", root .. "/escaped/main.lua",
        root .. "/local-require/main.lua",
        root .. "/runtime_main.lua")

    assert_contains(run("PATH=" .. shell_quote(root .. "/fakebin:" .. os.getenv("PATH"))
        .. " LUAI_LUA=" .. shell_quote(lua_bin)
        .. " " .. shell_quote(lua_bin) .. " -e " .. shell_quote(script)), "dependency edge cases ok")
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
assert(type(built.manifest.platform.host.os) == "string")
assert(type(built.manifest.platform.host.arch) == "string")
assert(type(built.manifest.platform.target.os) == "string")
assert(type(built.manifest.platform.target.arch) == "string")
local platform = require("luainstaller.platform")
local original_detect = platform.detectHost
platform.detectHost = function() return { os = "windows", arch = "x86_64" } end
local windows = manifest.build({
    entry = os.getenv("PWD") .. "/test/runtime_bundle/main.lua",
    dependencies = { scripts = {}, libraries = {} },
    mode = "onedir",
    out = "build/runtime.exe",
    target_os = "windows",
})
assert(windows.ok == true, windows.error and windows.error.message)
assert(windows.manifest.platform.target.os == "windows")
assert(windows.manifest.platform.target.arch == "x86_64")
assert(windows.manifest.launcher.profile == "windows-shared-lua")
platform.detectHost = function() return { os = "macos", arch = "arm64" } end
local macos = manifest.build({
    entry = os.getenv("PWD") .. "/test/runtime_bundle/main.lua",
    dependencies = { scripts = {}, libraries = {} },
    mode = "onedir",
    out = "build/runtime",
    target_os = "macos",
})
assert(macos.ok == true, macos.error and macos.error.message)
assert(macos.manifest.platform.target.os == "macos")
assert(macos.manifest.launcher.profile == "static-lua")
platform.detectHost = original_detect
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

local function check_logger_write_failure()
    local script = SOURCE_LOADER .. [[
local logger = require("luainstaller.logger")
assert(logger.clearLogs() == false, "clearLogs must report a persistence failure")
print("logger write failure ok")
]]
    assert_contains(run("HOME=/proc/luainstaller-unwritable lua -e " .. shell_quote(script)),
        "logger write failure ok")

    local short_write_script = SOURCE_LOADER .. [[
local logger = require("luainstaller.logger")
local saved_open = io.open
io.open = function()
    return {
        write = function() return nil, "simulated disk full" end,
        close = function() return true end,
    }
end
assert(logger.clearLogs() == false, "clearLogs must report a short write")
io.open = saved_open
print("logger short write failure ok")
]]
    assert_contains(run("lua -e " .. shell_quote(short_write_script)), "logger short write failure ok")
end

local function check_platform_profiles()
    local script = SOURCE_LOADER .. [[
local platform = require("luainstaller.platform")
local host = platform.detectHost()
assert(host.os == "linux" or host.os == "macos" or host.os == "windows" or host.os == "unknown")
assert(type(host.arch) == "string")

local original_detect = platform.detectHost
platform.detectHost = function() return { os = "linux", arch = "x86_64" } end
local linux = assert(platform.profile({ target_os = "linux" }))
assert(linux.executable_suffix == "")
assert(linux.native_extensions[1] == ".so")
assert(linux.loader_rpath == "$ORIGIN/.luai/native")
assert(type(linux.target_arch) == "string")
assert(linux.launcher_profile == "shared-lua")

platform.detectHost = function() return { os = "macos", arch = "arm64" } end
local macos = assert(platform.profile({ target_os = "macos", lua_prefix = "/tmp/lua" }))
assert(macos.executable_suffix == "")
assert(macos.native_extensions[1] == ".so")
assert(macos.native_extensions[2] == ".dylib")
assert(macos.loader_rpath == "@loader_path/.luai/native")
assert(macos.lua_prefix == "/tmp/lua")
assert(macos.launcher_profile == "static-lua")

platform.detectHost = function() return { os = "windows", arch = "x86_64" } end
local windows = assert(platform.profile({ target_os = "windows" }))
assert(windows.executable_suffix == ".exe")
assert(windows.native_extensions[1] == ".dll")
assert(windows.loader_rpath == nil)
assert(windows.target_arch == "x86_64")
assert(windows.launcher_profile == "windows-shared-lua")
local cross, cross_err = platform.profile({ target_os = "linux" })
assert(cross == nil and cross_err.error.type == "UnsupportedPlatformError")
platform.detectHost = original_detect
print("platform profiles ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "platform profiles ok")
end

local function check_macos_profile_host_and_toolchain()
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
local host_os = require("luainstaller.platform").detectHost().os
if host_os == "macos" then
    assert(result.error.type == "ToolchainError")
    assert(tostring(result.error.message):find("Lua prefix", 1, true))
else
    assert(result.error.type == "UnsupportedPlatformError")
end
print("macos profile host gate ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "macos profile host gate ok")
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
local host_os = require("luainstaller.platform").detectHost().os
if host_os == "windows" then
    assert(result.error.type == "ToolchainError")
    assert(tostring(result.error.message):find("Windows Lua prefix", 1, true))
else
    assert(result.error.type == "UnsupportedPlatformError")
end
print("windows profile toolchain ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "windows profile toolchain ok")
end

local function check_remote_onefile_script_coverage()
    local macos = read_file("tools/remote-test-macos.sh")
    assert_contains(macos, "bundle_onefile()")
    assert_contains(macos, "--file")
    assert_contains(macos, "mac-onefile-runtime")
    assert_contains(macos, "mac-onefile-student")
    assert_contains(macos, "LUAROCKS_TARBALL")
    assert_contains(macos, "stage_source \"$LUAROCKS_TARBALL\"")
    assert_not_contains(macos, "curl -fsSLO https://luarocks.org/releases")
    assert_contains(macos, "quote_remote()")
    assert_contains(macos, "copy_tree_macos()")
    assert_contains(macos, "REMOTE_ROOT=$(quote_remote \"$REMOTE_ROOT\")")
    assert_contains(macos, "rm -rf \"\\$ROCKTREE\"")
    assert_contains(macos, "mkdir -p \"\\$ROCKTREE\"")
    assert_contains(macos, "install --force lua-cjson 2.1.0.10-1")
    assert_contains(macos, "install --force luafilesystem 1.9.0-1")
    assert_contains(macos, "install --force luasocket 3.1.0-1")
    assert_contains(macos, "install --force mimetypes 1.1.0-2")
    assert_contains(macos, "install --force pegasus 1.1.0-0")
    assert_contains(macos, "git archive --format=tar HEAD")
    assert_contains(macos, "tools/test-lua-versions.sh")

    local windows = read_file("tools/remote-test-windows.sh")
    assert_contains(windows, "tools/test-lua-versions.ps1")
    assert_contains(windows, "command -v pwsh")
    assert_not_contains(windows:lower(), "ssh")
    assert_not_contains(windows:lower(), "wine")
    assert_not_contains(windows:lower(), "mingw")

    local linux = read_file("tools/remote-test-linux.sh")
    assert_contains(linux, "test/contract_docs.lua")
    assert_contains(linux, "test/cli_split_smoke.lua")
    assert_contains(linux, "luarocks make")
    assert_contains(linux, "git archive --format=tar HEAD")
    assert_contains(linux, "tools/test-lua-versions.sh")
    print("remote onefile script coverage ok")
end

local function check_release_safety_contract()
    local root = make_temp_dir("release-safety")
    local lua_bin = command_output_trimmed("command -v lua")
    local real_cc = command_output_trimmed("command -v cc")
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

    local forged_allowed_out = root .. "/forged-allowed-generated"
    run("mkdir -p " .. shell_quote(forged_allowed_out .. "/.luai"))
    write_file(forged_allowed_out .. "/.luai/manifest.lua", "-- generated by luainstaller\nreturn {}\n")
    write_file(forged_allowed_out .. "/forged-allowed-generated", "user executable")
    local forged_allowed_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local forged = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    max_deps = 120,
})
assert(forged.ok == false, "forged generated manifest with allowed names must not authorize deleting user files")
assert(forged.error.type == "InvalidOutputError")
print("forged allowed manifest safety ok")
]], forged_allowed_out)
    assert_contains(run("lua -e " .. shell_quote(forged_allowed_script)), "forged allowed manifest safety ok")
    assert(read_file(forged_allowed_out .. "/forged-allowed-generated") == "user executable")

    local onefile_path = root .. "/existing-onefile"
    write_file(onefile_path, "user executable")
    local onefile_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local result = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    mode = "onefile",
    out = %q,
    max_deps = 120,
})
assert(result.ok == false, "existing onefile output must be rejected unless explicitly forced")
assert(result.error.type == "InvalidOutputError")
print("onefile existing file safety ok")
]], onefile_path)
    assert_contains(run("lua -e " .. shell_quote(onefile_script)), "onefile existing file safety ok")
    assert(read_file(onefile_path) == "user executable")

    local marker = root .. "/logger-injected"
    local evil_home = root .. '/home"; touch ' .. marker .. '; echo "'
    local logger_script = SOURCE_LOADER .. [[
local logger = require("luainstaller.logger")
assert(logger.clearLogs() == true)
print("logger clear ok")
]]
    assert_contains(run("HOME=" .. shell_quote(evil_home) .. " lua -e " .. shell_quote(logger_script)), "logger clear ok")
    if file_exists(marker) then
        error("logger directory creation must not execute shell metacharacters from HOME", 2)
    end

    local rebuild_out = root .. "/rebuild-generated"
    local rebuild_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
for i = 1, 2 do
    local result = luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = %q,
        max_deps = 120,
    })
    assert(result.ok == true, result.error and result.error.message)
end
print("generated marker rebuild ok")
]], rebuild_out)
    assert_contains(run("lua -e " .. shell_quote(rebuild_script)), "generated marker rebuild ok")

    local failing_bin = root .. "/failing-toolchain"
    run("mkdir -p " .. shell_quote(failing_bin))
    write_file(failing_bin .. "/cc", [[
#!/bin/sh
echo "forced compiler failure" >&2
exit 1
]])
    run("chmod +x " .. shell_quote(failing_bin .. "/cc"))
    local failed_rebuild_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local result = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    max_deps = 120,
})
assert(result.ok == false, "forced toolchain failure must fail the rebuild")
assert(result.error.type == "ToolchainError")
print("failed rebuild reported")
]], rebuild_out)
    assert_contains(run("PATH=" .. shell_quote(failing_bin .. ":/usr/bin:/bin")
        .. " " .. shell_quote(lua_bin) .. " -e " .. shell_quote(failed_rebuild_script)),
        "failed rebuild reported")
    assert_file_exists(rebuild_out .. "/rebuild-generated")
    assert_contains(run(shell_quote(rebuild_out .. "/rebuild-generated") .. " preserved"), "hello preserved")

    local race_out = root .. "/appeared-during-build"
    local racing_bin = root .. "/racing-toolchain"
    run("mkdir -p " .. shell_quote(racing_bin))
    write_file(racing_bin .. "/cc", [[
#!/bin/sh
mkdir -p "$LUAI_RACE_OUT"
printf '%s\n' 'user data created during build' > "$LUAI_RACE_OUT/sentinel.txt"
exec "$LUAI_REAL_CC" "$@"
]])
    run("chmod +x " .. shell_quote(racing_bin .. "/cc"))
    local race_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local result = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    max_deps = 120,
})
assert(result.ok == false, "an output created during build must not be replaced")
assert(result.error.type == "InvalidOutputError")
print("onedir output race rejected")
]], race_out)
    assert_contains(run("LUAI_RACE_OUT=" .. shell_quote(race_out)
        .. " LUAI_REAL_CC=" .. shell_quote(real_cc)
        .. " PATH=" .. shell_quote(racing_bin .. ":/usr/bin:/bin")
        .. " " .. shell_quote(lua_bin) .. " -e " .. shell_quote(race_script)),
        "onedir output race rejected")
    assert(read_file(race_out .. "/sentinel.txt") == "user data created during build\n")

    local onefile_race_out = root .. "/onefile-appeared-during-build"
    local racing_cc_bin = root .. "/racing-cc"
    run("mkdir -p " .. shell_quote(racing_cc_bin))
    write_file(racing_cc_bin .. "/cc", [[
#!/bin/sh
printf '%s\n' 'user file created during build' > "$LUAI_RACE_ONEFILE_OUT"
exec "$LUAI_REAL_CC" "$@"
]])
    run("chmod +x " .. shell_quote(racing_cc_bin .. "/cc"))
    local onefile_race_script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
local result = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    mode = "onefile",
    out = %q,
    max_deps = 120,
})
assert(result.ok == false, "a onefile output created during build must not be replaced")
assert(result.error.type == "InvalidOutputError")
print("onefile output race rejected")
]], onefile_race_out)
    assert_contains(run("LUAI_RACE_ONEFILE_OUT=" .. shell_quote(onefile_race_out)
        .. " LUAI_REAL_CC=" .. shell_quote(real_cc)
        .. " PATH=" .. shell_quote(racing_cc_bin .. ":/usr/bin:/bin")
        .. " " .. shell_quote(lua_bin) .. " -e " .. shell_quote(onefile_race_script)),
        "onefile output race rejected")
    assert(read_file(onefile_race_out) == "user file created during build\n")

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
    assert_contains(windows_script, "test-lua-versions.ps1")
    assert_not_contains(windows_script:lower(), "ssh")
    assert_not_contains(windows_script:lower(), "wine")
    assert_not_contains(windows_script:lower(), "mingw")

    local test_readme = read_file("test/README.adoc")
    assert_contains(test_readme, "test-lua-versions.ps1")
    assert_contains(test_readme, "physical Windows host")
    assert_not_contains(test_readme, "tools/install-source.sh")

    local testing_guide = read_file("docs/TESTING.adoc")
    assert_contains(testing_guide, "test-lua-versions.ps1")
    assert_contains(testing_guide, "physical native hosts")
    assert_contains(testing_guide, "test/production_edges.lua")
    assert_not_contains(testing_guide, "tools/install-source.sh")

    remove_tree(root)
    print("release safety contract ok")
end

local function check_release_metadata_contract()
    local rockspec = read_file("luainstaller-1.0.0-1.rockspec")
    assert_contains(rockspec, '"lua >= 5.1, < 6.0"')
    local bundling = read_file("docs/BUNDLING.adoc")
    assert_contains(bundling, "luainstaller-generated-output-v2")
    assert_contains(bundling, "SHA-256")
    assert_not_contains(bundling, "32-bit FNV-1a")
    local direct = run("lua test/runtime_bundle/main.lua metadata")
    assert_contains(direct, "hello metadata")
    print("release metadata contract ok")
end

local function cli_command(program_name, args)
    local quoted = {}
    for i = 1, #args do
        quoted[#quoted + 1] = string.format("%q", args[i])
    end
    return "lua -e " .. shell_quote(SOURCE_LOADER .. string.format([[
local cli = require("luainstaller.cli")
os.exit(cli.main({ %s }, { program_name = %q, color = false, animations = false }))
]], table.concat(quoted, ", "), program_name))
end

local function check_cli_contract()
    local direct_help = run("lua src/cli.lua -h")
    assert_contains(direct_help, "luai -a <entry.lua>")

    local luai_help = run(cli_command("luai", { "-h" }))
    assert_contains(luai_help, "luai -a <entry.lua>")
    assert_contains(luai_help, "luai -t <entry.lua>")
    assert_contains(luai_help, "luai -b <entry.lua>")
    assert_not_contains(luai_help, "luainstaller analyze")

    assert_equals(
        run(cli_command("luai", { "-v" })),
        "luai 1.0.0\n"
    )

    local full_help = run(cli_command("luainstaller", { "help" }))
    assert_contains(full_help, "luainstaller analyze <entry.lua>")
    assert_contains(full_help, "luainstaller trace <entry.lua>")
    assert_contains(full_help, "luainstaller build <entry.lua>")
    assert_contains(full_help, "--discovery-mode")
    assert_contains(full_help, "--lua <path>")
    assert_not_contains(full_help, "--require-engine")
    assert_not_contains(full_help, "engines")

    assert_equals(
        run(cli_command("luainstaller", { "version" })),
        "luainstaller 1.0.0  LGPL 3.0 by WaterRun\n"
    )

    local bad_luai = run(cli_command("luai", { "build", "test/single_file/01_hello_luainstaller.lua" }), {
        expect_failure = true,
    })
    assert_contains(bad_luai, "error: unknown luai command: build")

    local bad_full = run(cli_command("luainstaller", { "-b", "test/single_file/01_hello_luainstaller.lua" }), {
        expect_failure = true,
    })
    assert_contains(bad_full, "error: unknown luainstaller command: -b")

    local analyzed = run(cli_command("luai", {
        "-a",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
    }))
    assert_contains(analyzed, "ok")
    assert_contains(analyzed, "scripts:")
    assert_contains(analyzed, "libraries:")

    local traced = run(cli_command("luai", {
        "-t",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
    }))
    assert_contains(traced, "trace")
    assert_contains(traced, "resolved")
    assert_contains(traced, "compatibility:")
    assert_contains(traced, "same OS, same architecture, same ABI, same Lua ABI")
    assert_contains(traced, "does not claim universal cross-platform output")

    local verbose_analyzed = run(cli_command("luai", {
        "-a",
        "test/student_management_system/main.lua",
        "--max-deps",
        "250",
        "--verbose",
    }))
    assert_contains(verbose_analyzed, "trace-records:")
    assert_contains(verbose_analyzed, "model")

    local bad_engines = run(cli_command("luainstaller", { "engines" }), {
        expect_failure = true,
    })
    assert_contains(bad_engines, "error: unknown luainstaller command: engines")

    local old_discovery_option = run(cli_command("luai", {
        "-a",
        "test/runtime_bundle/main.lua",
        "--require-engine",
        "runtime",
    }), {
        expect_failure = true,
    })
    assert_contains(old_discovery_option, "error: unknown option for analyze: --require-engine")

    local cli_out = make_temp_dir("cli-onedir")
    local bundled = run(cli_command("luai", {
        "-b",
        "--dir",
        "test/student_management_system/main.lua",
        "-o",
        cli_out,
        "--max-deps",
        "250",
    }))
    assert_contains(bundled, "ok")
    assert_contains(bundled, cli_out .. "/")
    remove_tree(cli_out)

    run("rm -rf -- -dash-out")
    local dash_bundled = run(cli_command("luai", {
        "-b",
        "--dir",
        "test/runtime_bundle/main.lua",
        "-o",
        "-dash-out",
        "--max-deps",
        "120",
    }))
    assert_contains(dash_bundled, "ok")
    assert_file_exists("-dash-out/-dash-out")
    run("rm -rf -- -dash-out")

    print("cli contract ok")
end

local function check_cli_source_lookup_safety()
    local root = make_temp_dir("cli-source-lookup")
    local script_name = "luai;touch${IFS}injected;#"
    run("cp src/cli.lua " .. shell_quote(root .. "/" .. script_name))
    os.execute("cd " .. shell_quote(root) .. " && lua " .. shell_quote(script_name)
        .. " >/dev/null 2>&1")
    assert(not file_exists(root .. "/injected"), "CLI source lookup must quote a bare script name")
    remove_tree(root)
    print("cli source lookup safety ok")
end

local function check_runtime_cgen()
    local script = SOURCE_LOADER .. [[
local runtime = require("luainstaller.runtime")
local cgen = require("luainstaller.cgen")

local stripped = runtime.stripSource("\239\187\191#!/usr/bin/env lua\nprint('ok')")
assert(stripped == "\nprint('ok')")

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

local order_root = assert(os.getenv("LUAI_CGEN_ORDER_ROOT"))
local function write_temp(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end
write_temp(order_root .. "/entry.lua", "print('entry')\n")
write_temp(order_root .. "/b.lua", "return { name = 'b' }\n")
write_temp(order_root .. "/c.lua", "return { name = 'c' }\n")
local ordered = cgen.generateBootstrap({
    entry = order_root .. "/entry.lua",
    dependencies = {
        scripts = {
            order_root .. "/c.lua",
            order_root .. "/b.lua",
        },
        libraries = {},
    },
    module_names = {
        [order_root .. "/c.lua"] = "c",
        [order_root .. "/b.lua"] = "b",
    },
})
local b_pos = ordered:find("%[\"b\"%] =")
local c_pos = ordered:find("%[\"c\"%] =")
assert(b_pos and c_pos and b_pos < c_pos, "generated payload modules must be emitted in sorted order")

print("runtime cgen ok")
]]
    local root = make_temp_dir("cgen-order")
    assert_contains(run("LUAI_CGEN_ORDER_ROOT=" .. shell_quote(root)
        .. " lua -e " .. shell_quote(script)), "runtime cgen ok")
    remove_tree(root)
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

    if not command_ok("cc --version") then
        remove_file("test/runtime_bundle/generated_launcher.c")
        print("c launcher compile skipped")
        return
    end

    local c_path = "test/runtime_bundle/generated_launcher.c"
    local exe_path = "test/runtime_bundle/generated_launcher"
    remove_file(exe_path)

    local link_flags
    if host_system() == "Darwin" then
        local prefix = assert(os.getenv("LUAI_LUA_PREFIX"), "macOS launcher test needs LUAI_LUA_PREFIX")
        assert_file_exists(prefix .. "/include/lua.h")
        assert_file_exists(prefix .. "/lib/liblua.a")
        link_flags = "-I" .. shell_quote(prefix .. "/include")
            .. " " .. shell_quote(prefix .. "/lib/liblua.a") .. " -lm"
    else
        if not command_ok("pkg-config --exists lua") then
            remove_file("test/runtime_bundle/generated_launcher.c")
            print("c launcher compile skipped")
            return
        end
        link_flags = "$(pkg-config --cflags --libs lua)"
    end
    local compile = string.format(
        "cc -std=c11 -Wall -Wextra -Werror -pedantic %s -o %s %s",
        shell_quote(c_path),
        shell_quote(exe_path),
        link_flags
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

    local manifest = assert(loadfile(runtime_out .. "/.luai/manifest.lua"))()
    assert(type(manifest.launcher.lua_runtime) == "table")
    if host_system() == "Darwin" then
        assert(manifest.launcher.lua_runtime.link_mode == "static")
        assert(manifest.launcher.lua_runtime.destination_path == nil)
        assert(manifest.launcher.lua_runtime.source_path:match("/lib/liblua%.a$"))
        local dynamic = command_output("otool -L " .. shell_quote(runtime_out .. "/runtime"))
        assert_not_contains(dynamic, "liblua")
    else
        local runtime_liblua = run("find " .. shell_quote(runtime_out .. "/.luai/native")
            .. " -type f -name 'liblua*.so*' | sort")
        assert_contains(runtime_liblua, "liblua")
        assert(manifest.launcher.lua_runtime.destination_path:match("^%.luai/native/liblua"))
    end
    if host_system() == "Linux" and command_ok("readelf --version") then
        local dynamic = command_output("readelf -d " .. shell_quote(runtime_out .. "/runtime"))
        assert_contains(dynamic, "$ORIGIN/.luai/native")
    end

    assert_contains(run(shell_quote(runtime_out .. "/runtime") .. " onedir"), "hello onedir")

    local student_data = root .. "/students.json"
    assert_contains(run(shell_quote(student_out .. "/student") .. " --data " .. shell_quote(student_data) .. " seed"), "Seeded 8 students")
    assert_contains(run(shell_quote(student_out .. "/student") .. " --data " .. shell_quote(student_data) .. " list --sort average"), "Ada Lovelace")

    local path_bin = root .. "/path-bin"
    local path_cwd = root .. "/path-cwd"
    local path_data = root .. "/students-via-path.json"
    run("mkdir -p " .. shell_quote(path_bin) .. " " .. shell_quote(path_cwd))
    run("ln -s " .. shell_quote(student_out .. "/student") .. " " .. shell_quote(path_bin .. "/student-via-path"))
    assert_contains(run("cd " .. shell_quote(path_cwd)
        .. " && env -i PATH=" .. shell_quote(path_bin .. ":/usr/bin:/bin")
        .. " LUA_PATH='' LUA_CPATH=''"
        .. " student-via-path --data " .. shell_quote(path_data) .. " seed"), "Seeded 8 students")

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
            "i=0",
            "while [ \"$i\" -lt 30 ]; do",
            "  if curl -fsS http://127.0.0.1:" .. port .. "/api/status -H 'X-Auth-Token: testtoken' | grep -F '\"ok\":true' >/dev/null; then exit 0; fi",
            "  sleep 0.2",
            "  if ! kill -0 \"$PID\" >/dev/null 2>&1; then cat \"$LOG\"; exit 1; fi",
            "  i=$((i + 1))",
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
    run("mkdir -m 700 " .. shell_quote(cache_root))
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile"), "hello onefile")
    local real_temp_root = root .. "/onefile-real-temp"
    local linked_temp_root = root .. "/onefile-linked-temp"
    run("mkdir -m 700 " .. shell_quote(real_temp_root)
        .. " && ln -s " .. shell_quote(real_temp_root) .. " " .. shell_quote(linked_temp_root))
    assert_contains(run("TMPDIR=" .. shell_quote(linked_temp_root) .. " "
        .. shell_quote(runtime_out) .. " onefile-linked-temp"), "hello onefile-linked-temp")
    local manifest_path = command_output_trimmed("find " .. shell_quote(cache_root) .. " -path '*/.luai/manifest.lua' | sort | head -n 1")
    if manifest_path == "" then
        error("onefile cache manifest was not extracted", 2)
    end
    local first_mtime = file_mtime(manifest_path)
    run("sleep 1")
    assert_contains(run("TMPDIR=" .. shell_quote(cache_root) .. " " .. shell_quote(runtime_out) .. " onefile-again"), "hello onefile-again")
    local second_mtime = file_mtime(manifest_path)
    if first_mtime ~= second_mtime then
        error("onefile cache rewrote matching extracted file", 2)
    end
    local inner_path = command_output_trimmed("find " .. shell_quote(cache_root)
        .. " -type f -name inner -print | sort | head -n 1")
    if inner_path == "" then
        error("onefile cache inner executable was not found", 2)
    end
    assert(command_ok("test -x " .. shell_quote(inner_path)), "onefile cache inner file is not executable")
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

    local payload_dir = manifest_path:match("^(.*)/%.luai/manifest%.lua$")
    assert(payload_dir, "onefile payload directory was not recognized")
    local cache_base = payload_dir:match("^(.*)/[^/]+$")
    assert(cache_base, "onefile cache root was not recognized")
    run("chmod 0777 " .. shell_quote(cache_base))
    local unsafe_cache = run("TMPDIR=" .. shell_quote(cache_root) .. " "
        .. shell_quote(runtime_out) .. " onefile-unsafe-cache", { expect_failure = true })
    assert_contains(unsafe_cache, "extraction failed")
    run("chmod 0700 " .. shell_quote(cache_base))

    local parent_symlink_target = root .. "/onefile-parent-symlink-target"
    run("rm -rf " .. shell_quote(payload_dir .. "/.luai")
        .. " && mkdir -p " .. shell_quote(parent_symlink_target)
        .. " && ln -s " .. shell_quote(parent_symlink_target) .. " " .. shell_quote(payload_dir .. "/.luai"))
    local unsafe_parent = run("TMPDIR=" .. shell_quote(cache_root) .. " "
        .. shell_quote(runtime_out) .. " onefile-parent-symlink", { expect_failure = true })
    assert_contains(unsafe_parent, "extraction failed")
    local victim_files = command_output_trimmed("find " .. shell_quote(parent_symlink_target) .. " -type f -print")
    assert(victim_files == "", "onefile extraction must not write through parent-directory symlinks")

    local student_data = root .. "/students-onefile.json"
    assert_contains(run(shell_quote(student_out) .. " --data " .. shell_quote(student_data) .. " seed"), "Seeded 8 students")
    assert_contains(run(shell_quote(student_out) .. " --data " .. shell_quote(student_data) .. " list --sort average"), "Ada Lovelace")
    remove_tree(root)
    print("onefile bundles ok")
end

local function check_onefile_build_temp_safety()
    local root = make_temp_dir("onefile-build-temp-safety")
    local temp_root = root .. "/tmp"
    local victim = root .. "/victim"
    local stage_parent = temp_root
        .. "/luainstaller-onefile-work-123-250000000-111111-1"
    local out_path = root .. "/onefile"
    run("mkdir -p " .. shell_quote(temp_root) .. " " .. shell_quote(victim))
    run("ln -s " .. shell_quote(victim) .. " " .. shell_quote(stage_parent))

    local script = SOURCE_LOADER .. string.format([[
local luainstaller = require("luainstaller")
os.time = function() return 123 end
os.clock = function() return 0.25 end
math.random = function() return 111111 end
local result = luainstaller.bundle({
    entry = "test/runtime_bundle/main.lua",
    mode = "onefile",
    out = %q,
    max_deps = 120,
})
assert(result.ok == true,
    result.error and result.error.message or "precreated staging symlink was not bypassed")
print("onefile build temp safety ok")
]], out_path)
    assert_contains(run("TMPDIR=" .. shell_quote(temp_root) .. " lua -e " .. shell_quote(script)),
        "onefile build temp safety ok")
    local victim_files = command_output_trimmed("find " .. shell_quote(victim) .. " -type f -print")
    assert(victim_files == "", "onefile build must not write through a staging parent symlink")
    remove_tree(root)
end

local function check_cli_discovery_runtime()
    local root = make_temp_dir("cli-discovery-runtime")
    write_file(root .. "/main.lua", [[
local name = arg[1] or "dynamic"
local mod = require(name)
print(mod.message())
]])
    write_file(root .. "/dynamic.lua", [[
return { message = function() return "cli runtime dynamic module" end }
]])

    local traced = run(cli_command("luai", {
        "-a",
        root .. "/main.lua",
        "-d",
        "runtime",
        "--",
        "dynamic",
    }))
    assert_contains(traced, "ok")
    assert_contains(traced, "dynamic.lua")
    remove_tree(root)
    print("cli discovery mode ok")
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
    assert_equals(
        run(shell_quote(tree .. "/bin/luainstaller") .. " version"),
        "luainstaller 1.0.0  LGPL 3.0 by WaterRun\n"
    )
    run("cd /tmp && " .. shell_quote(tree .. "/bin/luainstaller") .. " build --dir "
        .. shell_quote(os.getenv("PWD") .. "/test/runtime_bundle/main.lua")
        .. " -o " .. shell_quote(out_dir) .. " --max-deps 120")
    assert_contains(run(shell_quote(out_dir .. "/runtime") .. " installed"), "hello installed")
    remove_tree(root)
    print("installed cli bundle ok")
end

check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()
check_discovery_modes()
check_dependency_edge_cases()
check_compatibility_diagnostics()
check_manifest_without_popen()
check_bundler_without_popen()
check_logger_write_failure()
check_platform_profiles()
check_macos_profile_host_and_toolchain()
check_windows_profile_reaches_toolchain()
check_remote_onefile_script_coverage()
check_release_safety_contract()
check_release_metadata_contract()
check_cli_contract()
check_cli_source_lookup_safety()
check_runtime_cgen()
check_c_launcher()
check_onedir_bundles()
check_onefile_bundles()
check_onefile_build_temp_safety()
check_cli_discovery_runtime()
check_installed_cli_bundle()

print("all packaging-target samples passed comprehensive smoke audit")
