--[[
Dependency limits cover discovered, explicit, native and FFI inputs together.

Author:
    WaterRun
File:
    dependency_limits.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local root = assert(fs.makePrivateDirectory("dependency-limits"))
local old_cpath = package.cpath
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    local first = path.join(root, "first.lua")
    local second = path.join(root, "second.lua")
    assert(fs.writeFile(entry, "return true\n"))
    assert(fs.writeFile(first, "return 1\n"))
    assert(fs.writeFile(second, "return 2\n"))
    for _, limit in ipairs({2147483584, 1e100}) do
        for _, mode in ipairs({"static", "manual", "runtime"}) do
            for _, action in ipairs({"analyze", "trace", "compatibility", "bundle"}) do
                local output = path.join(root, "invalid-limit")
                local response = api[action]({entry=entry, max_deps=limit, discovery_mode=mode, out=output})
                assert(not response.ok and response.error.type == "InvalidOptionsError"
                    and response.error.option == "max_deps", "oversized dependency limit was accepted")
                assert(fs.pathType(output) == "missing")
            end
        end
    end
    for _, mode in ipairs({"static", "manual", "runtime"}) do
        local boundary = api.analyze({entry=entry, max_deps=2147483583, discovery_mode=mode})
        assert(boundary.ok, "largest portable dependency limit failed: "
            .. tostring(boundary.error and boundary.error.message))
    end
    local function rejected(response, label)
        assert(not response.ok and response.error.type == "DependencyLimitExceededError",
            label .. " did not enforce the dependency budget")
        assert(response.error.limit == 1 and response.error.current_count == 2,
            label .. " lost the structured dependency count")
    end
    for _, mode in ipairs({"static", "manual", "runtime"}) do
        for _, action in ipairs({"analyze", "trace", "compatibility", "bundle"}) do
            local output = path.join(root, action .. "-" .. mode)
            rejected(api[action]({entry=entry, include={first, second}, max_deps=1,
                discovery_mode=mode, out=output}), action .. "/" .. mode)
            assert(fs.pathType(output) == "missing", "rejected inputs created output")
        end
        local exact = api.analyze({entry=entry, include={first, second}, max_deps=2,
            discovery_mode=mode})
        assert(exact.ok and #exact.dependencies.scripts == 2, "exact limit rejected")
        local duplicate = api.analyze({entry=entry, include={first, first, entry}, max_deps=1,
            discovery_mode=mode})
        assert(duplicate.ok, "duplicate inputs or the entry consumed another dependency")
        local excluded = api.analyze({entry=entry, include={first, second}, exclude={second},
            max_deps=1, discovery_mode=mode})
        assert(excluded.ok and #excluded.dependencies.scripts == 1, "excluded input consumed the budget")
    end
    for _, program in ipairs({"luai", "luainstaller"}) do
        local code, _, output = harness.invoke_cli(program, {program == "luai" and "-a" or "analyze",
            entry, "-d", "manual", "--include", first, "--include", second, "--max-deps", "1"})
        assert(code == 1)
        harness.assert_contains(output, "DependencyLimitExceededError")
        harness.assert_not_contains(output, "stack traceback")
        local invalid_code, _, invalid_output = harness.invoke_cli(program,
            {program == "luai" and "-a" or "analyze", entry, "-d", "runtime", "--max-deps", "1e100"})
        assert(invalid_code == 1)
        harness.assert_contains(invalid_output, "InvalidOptionsError")
        harness.assert_not_contains(invalid_output, "LuaInstallerError")
    end
    assert(fs.writeFile(entry, "require('first')\n"))
    for _, mode in ipairs({"static", "runtime"}) do
        rejected(api.analyze({entry=entry, include={second}, max_deps=1, discovery_mode=mode}),
            "discovered plus explicit / " .. mode)
    end

    -- Analysis selects native files without executing them. Their content is
    -- immaterial to the dependency-count boundary under test.
    local extension = package.config:sub(1, 1) == "\\" and ".dll" or ".so"
    local native_first = path.join(root, "native_first" .. extension)
    local native_second = path.join(root, "native_second" .. extension)
    assert(fs.writeFile(native_first, "first native analysis fixture"))
    assert(fs.writeFile(native_second, "second native analysis fixture"))
    package.cpath = path.join(root, "?" .. extension) .. ";" .. old_cpath
    assert(fs.writeFile(entry, "require('native_first'); require('native_second')\n"))
    rejected(api.analyze({entry=entry, max_deps=1}), "native modules")
    local exact_native = api.analyze({entry=entry, max_deps=2})
    assert(exact_native.ok and #exact_native.dependencies.libraries == 2)
    assert(fs.writeFile(entry, "require('native_first'); require('first')\n"))
    rejected(api.analyze({entry=entry, max_deps=1}), "native plus Lua modules")

    if jit then
        assert(fs.writeFile(entry, "return true\n"))
        for _, mode in ipairs({"static", "manual", "runtime"}) do
            rejected(api.analyze({entry=entry, include={first}, ffi_libraries={fixture=native_first},
                max_deps=1, discovery_mode=mode}), "Lua plus FFI / " .. mode)
            local exact = api.analyze({entry=entry, include={first}, ffi_libraries={fixture=native_first},
                max_deps=2, discovery_mode=mode})
            assert(exact.ok and #exact.dependencies.scripts == 1 and #exact.dependencies.libraries == 1)
        end
        assert(fs.writeFile(entry, "require('native_first')\n"))
        local shared = api.analyze({entry=entry, ffi_libraries={fixture=native_first}, max_deps=1})
        assert(shared.ok and #shared.dependencies.libraries == 1, "one native/FFI input counted twice")
        rejected(api.analyze({entry=entry, ffi_libraries={first=native_first, alias=native_first}, max_deps=1}),
            "FFI alias count")
    end
end)
package.cpath = old_cpath
assert(fs.removeTree(root))
assert(called, failure)
print("combined dependency limits ok")
