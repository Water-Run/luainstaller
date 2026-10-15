--[[
Input budgets reject large data before parsing or generated-C amplification.

Author:
    WaterRun
File:
    resource_bounds.lua
Date:
    2026-10-12
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local api = require("luainstaller")
local root = assert(fs.makePrivateDirectory("resource-bounds"))
local file = path.join(root, "input.lua")
assert(fs.writeFile(file, "return 'bounded input'\n"))
local called, failure = pcall(function()
    local content, message, state = fs.readRegularFile(file, 8)
    assert(content == nil, "read budget was ignored")
    assert(type(message) == "string" and state and state.limit_exceeded and state.limit == 8,
        "read limit has no structured diagnostic")
    local enough = assert(fs.readRegularFile(file, 1024))
    assert(enough == "return 'bounded input'\n")
    assert(fs.writeFile(file, ""))
    assert(fs.readRegularFile(file, 1) == "", "empty-file semantics changed")
    assert(fs.writeFile(file, "return '" .. string.rep("x", 80) .. "'\n"))
    local rejected = api.analyze({entry=file, discovery_mode="static", max_source_bytes=32})
    assert(not rejected.ok and rejected.error.type == "ResourceLimitExceededError"
        and rejected.error.resource == "source-bytes" and rejected.error.limit == 32,
        rejected.error and rejected.error.message or "oversized entry was accepted")
    local dependency = path.join(root, "dependency.lua")
    assert(fs.writeFile(file, "require('dependency')\n"))
    assert(fs.writeFile(dependency, "return '" .. string.rep("x", 80) .. "'\n"))
    rejected = api.analyze({entry=file, discovery_mode="static", max_source_bytes=32})
    assert(not rejected.ok and rejected.error.type == "ResourceLimitExceededError"
        and rejected.error.path == dependency, "oversized dependency was not diagnosed")
    assert(fs.writeFile(file, "return true\n"))
    for _, action in ipairs({"analyze", "trace", "compatibility", "bundle"}) do
        for _, mode in ipairs({"static", "manual", "runtime"}) do
            local output = path.join(root, action .. "-" .. mode)
            local returned, response = pcall(api[action], {
                entry=file, discovery_mode=mode, include={dependency},
                max_source_bytes=32, out=output,
            })
            assert(returned, action .. "/" .. mode .. " escaped the result boundary: " .. tostring(response))
            assert(not response.ok and response.error.type == "ResourceLimitExceededError"
                and response.error.resource == "source-bytes" and response.error.limit == 32
                and response.error.path == dependency, "oversized manual include was not diagnosed")
            assert(fs.pathType(output) == "missing", "oversized input created an output")
        end
    end
    for _, program in ipairs({"luai", "luainstaller"}) do
        local code, _, output = harness.invoke_cli(program, {
            program == "luai" and "-a" or "analyze", file,
            "--include", dependency, "--max-source-bytes", "32",
        })
        assert(code == 1, "CLI accepted an oversized include")
        harness.assert_contains(output, "ResourceLimitExceededError")
        harness.assert_not_contains(output, "stack traceback")
    end
    assert(fs.writeFile(file, "require('dependency')\n"))
    assert(fs.writeFile(dependency, "return '123456789012345'\n"))
    rejected = api.analyze({entry=file, discovery_mode="static", max_source_bytes=128,
        max_bundle_bytes=32})
    assert(not rejected.ok and rejected.error.type == "ResourceLimitExceededError"
        and rejected.error.resource == "bundle-bytes", "aggregate source budget was ignored")
    for _, value in ipairs({0, -1, math.huge, 1.5}) do
        rejected = api.analyze({entry=file, max_source_bytes=value})
        assert(not rejected.ok and rejected.error.type == "InvalidOptionsError"
            and rejected.error.option == "max_source_bytes", "invalid budget was accepted")
    end
    assert(fs.writeFile(file, "while true do end\n"))
    rejected = api.analyze({entry=file, discovery_mode="runtime", runtime_timeout=0.2})
    assert(not rejected.ok and rejected.error.type == "RuntimeTimeoutError"
        and rejected.error.timeout_seconds == 0.2,
        rejected.error and rejected.error.message or "runtime deadline was ignored")
    assert(fs.writeFile(file, "require('dependency')\n"))
    rejected = api.analyze({entry=file, discovery_mode="runtime", max_trace_bytes=128})
    assert(not rejected.ok and rejected.error.type == "ResourceLimitExceededError"
        and rejected.error.resource == "trace-bytes" and rejected.error.limit == 128,
        rejected.error and rejected.error.message or "trace budget was ignored")
end)
assert(fs.removeTree(root))
assert(called, failure)
print("resource limits ok")
