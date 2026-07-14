--[[
@file test/contract_docs.lua
@brief Documentation-derived contract tests for luainstaller.

These tests exercise behavior promised in README.adoc and docs/*.adoc.
They intentionally build small fixtures in /tmp so the assertions are not
coupled to the implementation's sample applications.

Author:
    WaterRun
File:
    contract_docs.lua
Date:
    2026-06-27
Updated:
    2026-07-11
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local luainstaller = require("luainstaller")

local shell_quote = harness.shell_quote
local run = harness.run
local command_output_trimmed = harness.command_output_trimmed
local file_exists = harness.file_exists
local read_file = harness.read_file
local write_file = harness.write_file
local assert_contains = harness.assert_contains
local assert_not_contains = harness.assert_not_contains
local make_temp_dir = harness.make_temp_dir
local remove_tree = harness.remove_tree
local mkdir = harness.mkdir
local find_trace = harness.find_trace
local assert_error = harness.assert_error
local invoke_cli = harness.invoke_cli

local function check_cli_surfaces_contract()
    local code, out, err = invoke_cli("luai", { "-h" })
    assert(code == 0)
    assert_contains(out, "Usage: luai")
    assert(err == "")

    code, out, err = invoke_cli("luainstaller", { "help" })
    assert(code == 0)
    assert_contains(out, "Usage: luainstaller")
    assert(err == "")

    code, out, err = invoke_cli("luai", { "build", "app.lua" })
    assert(code ~= 0)
    assert(out == "")
    assert_contains(err, "unknown luai command")

    code, out, err = invoke_cli("luainstaller", { "-b", "app.lua" })
    assert(code ~= 0)
    assert(out == "")
    assert_contains(err, "unknown luainstaller command")

    local root = make_temp_dir("cli-runtime-args")
    mkdir(root .. "/app")
    write_file(root .. "/app/main.lua", [[
local name = arg[1]
if name == "--plugin=alpha" then
    require("alpha")
else
    require("beta")
end
]])
    write_file(root .. "/app/alpha.lua", "return { name = 'alpha' }\n")
    write_file(root .. "/app/beta.lua", "return { name = 'beta' }\n")

    code, out, err = invoke_cli("luainstaller", {
        "analyze",
        root .. "/app/main.lua",
        "--discovery-mode",
        "runtime",
        "--lua",
        command_output_trimmed("command -v lua"),
        "--",
        "--plugin=alpha",
    })
    assert(code == 0)
    assert_contains(out, "Analysis complete")
    assert_contains(out, "Lua scripts: 1")
    assert(err == "")
    remove_tree(root)

    print("cli surfaces contract ok")
end

local function check_discovery_contracts()
    local root = make_temp_dir("discovery")
    mkdir(root .. "/app/plugin")
    write_file(root .. "/app/main.lua", [[
local model = require("model")
local storage = require 'storage'
local reports = require([=[reports]=])
local ok, optional = pcall(require, "optional.missing")
print(model.name, storage.name, reports.name, ok, optional)
]])
    write_file(root .. "/app/model.lua", "return { name = 'model' }\n")
    write_file(root .. "/app/storage.lua", "return { name = 'storage' }\n")
    write_file(root .. "/app/reports.lua", "return { name = 'reports' }\n")
    write_file(root .. "/app/plugin/manual.lua", "return { name = 'manual' }\n")

    local analyzed = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        max_deps = 20,
    })
    assert(analyzed.ok == true, analyzed.error and analyzed.error.message)
    assert(#analyzed.dependencies.scripts == 3, "static literal discovery should find three required Lua modules")
    assert(find_trace(analyzed.trace, "model"))
    assert(find_trace(analyzed.trace, "storage"))
    assert(find_trace(analyzed.trace, "reports"))
    local optional = assert(find_trace(analyzed.trace, "optional.missing"))
    assert(optional.optional == true)
    assert(optional.classification == "missing")
    assert(optional.reason == "optional-missing")

    local manual = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        discovery_mode = "manual",
        include = { root .. "/app/plugin/manual.lua", root .. "/app/storage.lua" },
        exclude = { "storage.lua" },
        max_deps = 20,
    })
    assert(manual.ok == true, manual.error and manual.error.message)
    assert(#manual.dependencies.scripts == 1, "manual discovery should include explicit files after excludes")
    assert(manual.dependencies.scripts[1]:match("plugin/manual%.lua$"))

    local dynamic_root = root .. "/dynamic"
    mkdir(dynamic_root)
    write_file(dynamic_root .. "/main.lua", [[
local name = "dynamic"
require(name)
require("plugin." .. name)
]])
    local dynamic = luainstaller.analyze({
        entry = dynamic_root .. "/main.lua",
        max_deps = 20,
    })
    assert_error(dynamic, "DynamicRequireError")
    assert_contains(dynamic.error.message, "dynamic")

    local limit_root = root .. "/limit"
    mkdir(limit_root)
    write_file(limit_root .. "/main.lua", "require('a')\n")
    write_file(limit_root .. "/a.lua", "require('b')\nreturn {}\n")
    write_file(limit_root .. "/b.lua", "return {}\n")
    local limited = luainstaller.analyze({
        entry = limit_root .. "/main.lua",
        max_deps = 1,
    })
    assert_error(limited, "DependencyLimitExceededError")

    local missing_include = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        discovery_mode = "manual",
        include = { root .. "/app/no-such-plugin.lua" },
    })
    assert_error(missing_include, "ScriptNotFoundError")

    remove_tree(root)
    print("discovery contracts ok")
end

local function check_manual_exclude_contracts()
    local root = make_temp_dir("manual-exclude")
    mkdir(root .. "/app/auto")
    mkdir(root .. "/app/plugin")
    write_file(root .. "/app/main.lua", [[
require("auto.alpha")
require("auto.storage")
require("plugin.extra")
]])
    write_file(root .. "/app/auto/alpha.lua", "return { name = 'alpha' }\n")
    write_file(root .. "/app/auto/storage.lua", "return { name = 'storage' }\n")
    write_file(root .. "/app/plugin/extra.lua", "return { name = 'extra' }\n")

    local alpha = root .. "/app/auto/alpha.lua"
    local storage = root .. "/app/auto/storage.lua"
    local extra = root .. "/app/plugin/extra.lua"

    local automatic = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        exclude = { alpha, "storage.lua", "plugin/extra.lua" },
        max_deps = 20,
    })
    assert(automatic.ok == true, automatic.error and automatic.error.message)
    assert(#automatic.dependencies.scripts == 0,
        "exclude must win over automatic discovery by exact path, basename, and path-suffix")

    local manual = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        discovery_mode = "manual",
        include = { alpha, storage, extra },
        exclude = { alpha, "storage.lua", "plugin/extra.lua" },
        max_deps = 20,
    })
    assert(manual.ok == true, manual.error and manual.error.message)
    assert(#manual.dependencies.scripts == 0,
        "exclude must win over manual includes by exact path, basename, and path-suffix")

    local no_depscan = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        depscan = false,
        include = { extra },
        max_deps = 20,
    })
    assert(no_depscan.ok == true, no_depscan.error and no_depscan.error.message)
    assert(#no_depscan.dependencies.scripts == 1,
        "--no-depscan/depscan=false must disable automatic scanning and keep manual includes")
    assert(no_depscan.dependencies.scripts[1]:match("plugin/extra%.lua$"))
    assert(not find_trace(no_depscan.trace, "auto.alpha"))
    assert(find_trace(no_depscan.trace, "plugin.extra"))

    -- Basename exclude must not match a longer suffix (util.lua vs myutil.lua).
    write_file(root .. "/app/main2.lua", "require('myutil')\n")
    write_file(root .. "/app/myutil.lua", "return { name = 'myutil' }\n")
    local suffix_trap = luainstaller.analyze({
        entry = root .. "/app/main2.lua",
        exclude = { "util.lua" },
        max_deps = 20,
    })
    assert(suffix_trap.ok == true, suffix_trap.error and suffix_trap.error.message)
    assert(#suffix_trap.dependencies.scripts == 1,
        "excluding util.lua must not drop myutil.lua")
    assert(suffix_trap.dependencies.scripts[1]:match("myutil%.lua$"))

    remove_tree(root)
    print("manual and exclude contracts ok")
end

local function check_runtime_discovery_contract()
    local root = make_temp_dir("runtime")
    mkdir(root .. "/app")
    write_file(root .. "/app/main.lua", [[
if arg[1] == "alpha" then
    require("alpha")
else
    require("beta")
end
]])
    write_file(root .. "/app/alpha.lua", "return { name = 'alpha' }\n")
    write_file(root .. "/app/beta.lua", "return { name = 'beta' }\n")

    local runtime = luainstaller.analyze({
        entry = root .. "/app/main.lua",
        discovery_mode = "runtime",
        run_args = { "alpha" },
        lua = command_output_trimmed("command -v lua"),
        max_deps = 20,
    })
    assert(runtime.ok == true, runtime.error and runtime.error.message)
    assert(#runtime.dependencies.scripts == 1, "runtime discovery should record only the executed branch")
    assert(runtime.dependencies.scripts[1]:match("alpha%.lua$"))
    assert(find_trace(runtime.trace, "alpha"))
    assert(not find_trace(runtime.trace, "beta"))

    remove_tree(root)
    print("runtime discovery contract ok")
end

local function check_option_validation_contracts()
    assert_error(luainstaller.analyze(nil), "InvalidOptionsError")
    assert_error(luainstaller.analyze({}), "InvalidOptionsError")
    assert_error(luainstaller.analyze({ entry = "" }), "InvalidOptionsError")
    assert_error(luainstaller.analyze({
        entry = "test/runtime_bundle/main.lua",
        discovery_mode = "sideways",
    }), "InvalidOptionsError")
    assert_error(luainstaller.trace({
        entry = "test/runtime_bundle/main.lua",
        target_os = "plan9",
    }), "UnsupportedPlatformError")
    assert_error(luainstaller.analyze({
        entry = "test/runtime_bundle/main.lua",
        max_deps = 0,
    }), "InvalidOptionsError")
    assert_error(luainstaller.analyze({
        entry = "test/runtime_bundle/main.lua",
        include = { 42 },
    }), "InvalidOptionsError")
    assert_error(luainstaller.analyze({
        entry = "test/runtime_bundle/main.lua",
        exclude = { false },
    }), "InvalidOptionsError")
    assert_error(luainstaller.analyze({
        entry = "test/runtime_bundle/main.lua",
        run_args = { {} },
    }), "InvalidOptionsError")
    print("option validation contracts ok")
end

local function check_output_safety_contracts()
    assert_error(luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = "",
        max_deps = 20,
    }), "InvalidOutputError")
    assert_error(luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = ".",
        max_deps = 20,
    }), "InvalidOutputError")
    assert_error(luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = "/",
        max_deps = 20,
    }), "InvalidOutputError")

    local cwd = command_output_trimmed("pwd")
    assert_error(luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = cwd,
        max_deps = 20,
    }), "InvalidOutputError")

    local root = make_temp_dir("output-safety")
    local target = root .. "/target"
    local link = root .. "/link"
    mkdir(target)
    if os.execute("ln -s " .. shell_quote(target) .. " " .. shell_quote(link) .. " >/dev/null 2>&1") == true
        or os.execute("test -L " .. shell_quote(link) .. " >/dev/null 2>&1") == true then
        assert_error(luainstaller.bundle({
            entry = "test/runtime_bundle/main.lua",
            out = link,
            max_deps = 20,
        }), "InvalidOutputError")
        assert_error(luainstaller.bundle({
            entry = "test/runtime_bundle/main.lua",
            out = link,
            mode = "onefile",
            max_deps = 20,
        }), "InvalidOutputError")
    end
    remove_tree(root)
    print("output safety contracts ok")
end

local function check_manifest_and_marker_contracts()
    local root = make_temp_dir("manifest")
    local out = root .. "/runtime-demo"
    local bundled = luainstaller.bundle({
        entry = "test/runtime_bundle/main.lua",
        out = out,
        max_deps = 120,
    })
    assert(bundled.ok == true, bundled.error and bundled.error.message)

    local manifest_path = out .. "/.luai/manifest.lua"
    local marker_path = out .. "/.luai/generated-output.txt"
    assert(file_exists(manifest_path), "manifest must be inspectable Lua data")
    assert(file_exists(marker_path), "generated output marker must be written")
    assert_contains(read_file(manifest_path), "-- generated by luainstaller")
    local manifest = assert(loadfile(manifest_path))()
    assert(manifest.version == 2)
    assert(manifest.hash_algorithm == "sha256")
    assert(#manifest.entry.content_hash == 64)
    assert(type(manifest.platform.host.os) == "string")
    assert(type(manifest.platform.host.arch) == "string")
    assert(type(manifest.platform.target.os) == "string")
    assert(type(manifest.platform.target.arch) == "string")
    assert(manifest.output.mode == "onedir")
    assert(type(manifest.modules.lua) == "table")
    assert(type(manifest.modules.native) == "table")
    assert(type(manifest.trace) == "table")
    assert(type(manifest.compatibility) == "table")
    assert(not file_exists(out .. "/.luai/lua"), "onedir embeds Lua sources instead of copying them as files")

    local marker = read_file(marker_path)
    assert_contains(marker, "luainstaller-generated-output-v2")
    assert_contains(marker, "output_dir=" .. out)
    assert_contains(marker, "dir\t.luai/build")
    assert_contains(marker, "file\t.luai/manifest.lua\t")
    local marked_executable = false
    for line in marker:gmatch("[^\n]+") do
        local kind, name, hash = line:match("^(file)\t([^\t]+)\t(%x+)$")
        if kind == "file" and name == out:match("([^/]+)$") and #hash == 64 then
            marked_executable = true
        end
    end
    assert(marked_executable, "generated marker must record a top-level generated file and hash")

    local exe = out .. "/" .. out:match("([^/]+)$")
    assert_contains(run("env -i PATH=/usr/bin:/bin " .. shell_quote(exe) .. " contract"), "hello contract")
    remove_tree(root)
    print("manifest and marker contracts ok")
end

local function check_bundled_searcher_contract()
    local root = make_temp_dir("searcher")
    mkdir(root .. "/app")
    mkdir(root .. "/host")
    local entry = root .. "/app/main.lua"
    write_file(entry, [[
package.preload["preload_override"] = function()
    return { source = "preload" }
end
local shadow = require("shadow")
local override = require("preload_override")
print("shadow=" .. shadow.source)
print("override=" .. override.source)
]])
    write_file(root .. "/app/shadow.lua", "return { source = 'bundled' }\n")
    write_file(root .. "/app/preload_override.lua", "return { source = 'bundled-preload' }\n")
    write_file(root .. "/host/shadow.lua", "return { source = 'host' }\n")

    local out = root .. "/searcher-demo"
    local bundled = luainstaller.bundle({
        entry = entry,
        out = out,
        max_deps = 20,
    })
    assert(bundled.ok == true, bundled.error and bundled.error.message)

    local exe = out .. "/" .. out:match("([^/]+)$")
    local output = run("cd " .. shell_quote(root .. "/host")
        .. " && env -i PATH=/usr/bin:/bin LUA_PATH='./?.lua;;' " .. shell_quote(exe))
    assert_contains(output, "shadow=bundled")
    assert_contains(output, "override=preload")
    assert_not_contains(output, "shadow=host")
    assert_not_contains(output, "override=bundled-preload")

    remove_tree(root)
    print("bundled searcher contract ok")
end

local function check_logging_contracts()
    local root = make_temp_dir("logs")
    local home = root .. "/home"
    mkdir(home)
    local script = harness.loader_prelude() .. [[
local luainstaller = require("luainstaller")
assert(luainstaller.clearLogs() == true)
assert(luainstaller.analyze({ entry = "test/no-such-file.lua" }).ok == false)
local all = luainstaller.getLogs({ limit = 10 })
assert(#all >= 1)
local errors = luainstaller.getLogs({ level = luainstaller.LogLevel.ERROR, limit = 1 })
assert(#errors == 1)
assert(errors[1].level == luainstaller.LogLevel.ERROR)
assert(errors[1].action == "analyze")
assert(errors[1].details.error_type == "ScriptNotFoundError")
local log_path = os.getenv("HOME") .. "/.luainstaller/logs.lua"
local input = assert(io.open(log_path, "rb"))
local persisted = assert(input:read("*a"))
assert(input:close())
local chunk = assert(load(persisted, "@logs.lua", "t", {}))
assert(type(chunk()) == "table", "persisted logs must remain loadable")
assert(os.execute("test ! -e " .. require("luainstaller.process").shellQuote(log_path .. ".lock")))
assert(luainstaller.clearLogs() == true)
assert(#luainstaller.getLogs({ limit = 10 }) == 0)
print("logging contract child ok")
]]
    assert_contains(run("HOME=" .. shell_quote(home) .. " lua -e " .. shell_quote(script)), "logging contract child ok")
    remove_tree(root)
    print("logging contracts ok")
end

local function check_documentation_contract()
    local expected_docs = {
        "docs/BUNDLING.adoc",
        "docs/IMPLEMENTATION.adoc",
        "docs/PLATFORMS-NATIVE-LIMITS.adoc",
        "docs/TESTING.adoc",
        "docs/TROUBLESHOOTING.adoc",
        "docs/USAGE.adoc",
    }
    local docs = {}
    local listing = run("find docs -type f -name '*.adoc' -print")
    for path in listing:gmatch("[^\r\n]+") do
        docs[#docs + 1] = path
    end
    table.sort(docs)
    assert(#docs == #expected_docs, "docs/ must contain exactly the documented guides")
    for index, path in ipairs(expected_docs) do
        assert(docs[index] == path, "unexpected documentation path: " .. tostring(docs[index]))
        local text = read_file(path)
        assert_contains(text, "xref:../README.adoc#documentation-index[Back to documentation index]")
    end

    local implementation = read_file("docs/IMPLEMENTATION.adoc")
    assert_contains(implementation, "luainstaller-generated-output-v2")
    assert_contains(implementation, "SHA-256")
    assert_contains(implementation, "loader data")
    assert_contains(implementation, "SourceChangedError")

    local bundling = read_file("docs/BUNDLING.adoc")
    assert_contains(bundling, "one-time removal")
    assert_contains(bundling, "recursive")
    assert_contains(bundling, "exact file set")
    assert_not_contains(bundling, "32-bit FNV-1a")

    local usage = read_file("docs/USAGE.adoc")
    assert_contains(usage, "Lua 5.4")
    assert_contains(usage, "entry-rooted")
    assert_contains(usage, "same environment")

    local testing = read_file("docs/TESTING.adoc")
    assert_contains(testing, "test/production_edges.lua")
    assert_contains(testing, "StrictHostKeyChecking=yes")
    assert_contains(testing, "WINDOWS_LOCAL_ONLY=1")
    assert_contains(testing, "SHA-256")

    local platform_limits = read_file("docs/PLATFORMS-NATIVE-LIMITS.adoc")
    assert_contains(platform_limits, "Lua >= 5.4 and < 5.5")
    assert_contains(platform_limits, "exactly Lua 5.4")

    local troubleshooting = read_file("docs/TROUBLESHOOTING.adoc")
    assert_contains(troubleshooting, "LuaSyntaxError")
    assert_contains(troubleshooting, "SourceChangedError")
    assert_contains(troubleshooting, "luainstaller-generated-output-v2")

    local manpage = read_file("luainstaller.1")
    assert_contains(manpage, "Lua 5.4")
    assert_contains(manpage, [[SHA\-256]])
    assert_contains(manpage, "luainstaller-generated-output-v2")

    local rockspec = read_file("luainstaller-1.0.0-1.rockspec")
    assert_contains(rockspec, '"lua >= 5.1, < 6.0"')

    local direct_output = run("lua test/runtime_bundle/main.lua docs")
    assert_contains(direct_output, "hello docs")

    local all_docs = table.concat({
        read_file("README.adoc"),
        read_file("docs/TESTING.adoc"),
        read_file("test/README.adoc"),
    }, "\n")
    assert_contains(all_docs, "test/contract_docs.lua")
    assert_contains(all_docs, "support/")
    assert_not_contains(all_docs, "xref:docs/README.adoc")
    assert_not_contains(all_docs, "link:docs/README.adoc")
    assert_not_contains(all_docs, "xref:docs/CLI.adoc")
    assert_not_contains(all_docs, "link:docs/CLI.adoc")
    print("documentation contract ok")
end

check_cli_surfaces_contract()
check_discovery_contracts()
check_manual_exclude_contracts()
check_runtime_discovery_contract()
check_option_validation_contracts()
check_output_safety_contracts()
check_manifest_and_marker_contracts()
check_bundled_searcher_contract()
check_logging_contracts()
check_documentation_contract()

print("documentation-derived contracts passed")
