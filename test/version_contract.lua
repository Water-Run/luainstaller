--[[
Lua-version compatibility contract tests for luainstaller.

Author:
    WaterRun
File:
    version_contract.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local compat = require("luainstaller.compat")
local info = compat.luaVersion()

assert(info.major == 5, "Lua 5.x is required")
assert(info.minor >= 1, "Lua 5.1 or newer is required")
assert(info.official == true, "the matrix must run an official Lua interpreter")
assert(info.abi == string.format("lua%d.%d", info.major, info.minor))
assert(info.num == info.major * 100 + info.minor)

local interpreter = harness.lua_command()
assert(type(interpreter) == "string" and interpreter ~= "")
local output = harness.run_lua({ "-e", "io.write(_VERSION)" })
assert(output == _VERSION, string.format(
    "child interpreter mismatch: expected %s, got %s",
    _VERSION,
    tostring(output)
))

local process = require("luainstaller.process")
local output_succeeded, direct_output = process.output(harness.command(interpreter, {
    "-e",
    "io.write('process-output-ok')",
}))
assert(output_succeeded and direct_output == "process-output-ok",
    "child process success and output must be observable")
local child_succeeded = process.output(harness.command(interpreter, {
    "-e",
    "os.exit(7)",
}))
assert(child_succeeded == false, "child process failure must be observable")

assert(compat.band(0xf0, 0x3c) == 0x30)
assert(compat.bor(0xf0, 0x0f) == 0xff)
assert(compat.bxor(0xaa, 0xff) == 0x55)
assert(compat.bnot(0) == 0xffffffff)
assert(compat.lshift(0x12, 8) == 0x1200)
assert(compat.rshift(0x12345678, 8) == 0x00123456)
assert(compat.rrotate(0x12345678, 8) == 0x78123456)
assert(compat.packU32BE(0x12345678) == "\18\52\86\120")

local loaded = assert(compat.loadText("return value", "@compat", { value = 42 }))
assert(loaded() == 42)
local bytecode = string.dump(function() return true end)
local rejected, reject_error = compat.loadText(bytecode, "@bytecode", {})
assert(rejected == nil)
assert(type(reject_error) == "string" and reject_error ~= "")

local hash = require("luainstaller.hash")
assert(hash.sha256("abc") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
if info.minor >= 3 then
    assert(hash.backend() == "native-operators")
    local started = os.clock()
    hash.sha256(string.rep("a", 1024 * 1024))
    local elapsed = os.clock() - started
    assert(elapsed < 3, string.format("native SHA-256 backend is too slow: %.2fs", elapsed))
else
    local started = os.clock()
    hash.sha256(string.rep("a", 128 * 1024))
    local elapsed = os.clock() - started
    assert(elapsed < 15, string.format("portable SHA-256 backend is too slow: %.2fs", elapsed))
end

local product_files = {
    "src/analyzer.lua",
    "src/bundler.lua",
    "src/cgen.lua",
    "src/cli.lua",
    "src/compat.lua",
    "src/discovery.lua",
    "src/fs.lua",
    "src/hash.lua",
    "src/init.lua",
    "src/launcher.lua",
    "src/logger.lua",
    "src/lua_abi.lua",
    "src/manifest.lua",
    "src/onefile.lua",
    "src/path.lua",
    "src/platform.lua",
    "src/process.lua",
    "src/result.lua",
    "src/runtime.lua",
    "src/toolchain.lua",
}
for _, path in ipairs(product_files) do
    local chunk, load_error = loadfile(path)
    assert(chunk, path .. ": " .. tostring(load_error))
end

local analyzed = require("luainstaller").analyze({
    entry = "test/runtime_bundle/main.lua",
    max_deps = 120,
})
assert(analyzed.ok, analyzed.error and analyzed.error.message)
assert(#analyzed.dependencies.scripts == 1)

local original_jit = rawget(_G, "jit")
rawset(_G, "jit", { version = "simulated LuaJIT", status = function() return true end })
local jit_result = require("luainstaller").analyze({
    entry = "test/runtime_bundle/main.lua",
})
rawset(_G, "jit", original_jit)
assert(not jit_result.ok and jit_result.error.type == "UnsupportedLuaVersionError",
    "LuaJIT-compatible runtimes must be rejected")

local runtime = require("luainstaller.runtime")
local returned = compat.pack(runtime.run({
    entry = {
        path = "version-contract-entry.lua",
        source = "local m = require('version_contract_module'); return m.values()",
    },
    modules = {
        version_contract_module = {
            path = "version-contract-module.lua",
            source = "return { values = function() return 17, nil, 29 end }",
        },
    },
}))
assert(returned.n == 3 and returned[1] == 17 and returned[2] == nil and returned[3] == 29)

local cgen = require("luainstaller.cgen")
local bootstrap = cgen.generateBootstrap({
    entry = "test/runtime_bundle/main.lua",
    dependencies = {
        scripts = { "test/runtime_bundle/greeter.lua" },
        libraries = {},
    },
})
local generated = assert(compat.loadText(bootstrap, "@version-contract-bootstrap", _G))
local old_arg = _G.arg
_G.arg = { [0] = "version-contract-bundle", [1] = "embedded" }
local generated_ok, generated_error = pcall(generated)
_G.arg = old_arg
assert(generated_ok, generated_error)

if package.config:sub(1, 1) ~= "\\" then
    local trace_root = harness.make_temp_dir("version-trace")
    harness.write_file(trace_root .. "/main.lua", [[
local loaded = require("version_contract_trace_module")
assert(loaded.value == 41)
]])
    harness.write_file(trace_root .. "/version_contract_trace_module.lua",
        "return { value = 41 }\n")
    local traced = require("luainstaller").analyze({
        entry = trace_root .. "/main.lua",
        discovery_mode = "runtime",
        lua = interpreter,
        max_deps = 120,
    })
    harness.remove_tree(trace_root)
    assert(traced.ok, traced.error and (traced.error.message
        .. "\n" .. tostring(traced.error.output or "")))
    assert(#traced.dependencies.scripts == 1, string.format(
        "expected one runtime dependency, got %d (trace=%d): %s",
        #traced.dependencies.scripts,
        #(traced.trace or {}),
        table.concat(traced.dependencies.scripts, ", ")
    ))
end

print("version contract ok: " .. info.version)
