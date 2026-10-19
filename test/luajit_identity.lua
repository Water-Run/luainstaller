--[[
Runtime identity and LuaJIT builtin boundaries.

Author:
    WaterRun
File:
    luajit_identity.lua
Date:
    2026-10-15
Updated:
    2026-10-20
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local lua_abi = require("luainstaller.lua_abi")
local compat = require("luainstaller.compat")
local analyzer = require("luainstaller.analyzer")

local info = compat.luaVersion()
local hash = require("luainstaller.hash")
assert(hash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
assert(hash.sha256(string.rep("a", 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
local is_jit = type(rawget(_G, "jit")) == "table"
assert(info.kind == (is_jit and "luajit" or "lua"), "runtime kind must be independent of ABI")
assert(info.official == not is_jit)
assert(info.supported)
assert(lua_abi.validateInfo(info))
assert(lua_abi.current() == _VERSION:match("(%d+%.%d+)$"))
assert(lua_abi.isOfficialCurrent() == not is_jit)
if not is_jit then
    local invalid = require("luainstaller").analyze({entry="test/runtime_bundle/main.lua",
        ffi_libraries={example="does-not-exist.so"}})
    assert(not invalid.ok and invalid.error.type == "InvalidOptionsError")
end
local check = assert((loadstring or load)(lua_abi.checkSource(info), "@identity-check"))
assert(check())

local resolver = analyzer.ModuleResolver.new("test")
for _, name in ipairs({ "bit", "jit", "ffi", "jit.util", "jit.opt", "jit.profile", "string.buffer" }) do
    assert(resolver:isBuiltin(name) == is_jit, name .. " runtime builtin classification")
end
for _, name in ipairs({ "jit.bc", "jit.dump", "jit.v", "jit.p", "jit.dis_x64", "jit.unknown" }) do
    assert(not resolver:isBuiltin(name), name .. " must be resolved as a file")
end

if is_jit then
    assert(info.abi == "lua5.1" and info.num == 501)
    assert(info.runtime_version == jit.version)
    assert(info.jit_compiler)
    assert(info.gc64 == require("ffi").abi("gc64"))
    local rawlen_value = rawget(_G, "rawlen")
    rawset(_G, "rawlen", function() return 0 end)
    local unchanged = lua_abi.info().lua52compat
    rawset(_G, "rawlen", rawlen_value)
    assert(unchanged == info.lua52compat, "a user global changed the detected build configuration")
    local limited = {}
    for key, value in pairs(info) do limited[key] = value end
    limited.string_buffer = false
    assert(not lua_abi.isBuiltin(limited, "string.buffer"), "missing optional builtins must resolve as dependencies")
    local pinned = os.getenv("LUAI_JIT_RELEASE")
    if pinned then
        assert(require("luainstaller").VERSION == "1.8.2")
        assert(jit.version == "LuaJIT " .. pinned, "matrix runtime does not match the pinned source")
        local platform = require("luainstaller.platform")
        local runtime_arch = platform.normalizeArch(jit.arch)
        assert(runtime_arch == platform.detectHost().arch,
            "LuaJIT runtime architecture does not match the native host")
        local expected_arch = os.getenv("LUAI_EXPECT_HOST_ARCH")
        if expected_arch and expected_arch ~= "" then
            assert(runtime_arch == platform.normalizeArch(expected_arch),
                "LuaJIT matrix architecture mismatch: expected " .. expected_arch
                    .. ", got " .. runtime_arch)
        end
        local configuration = os.getenv("LUAI_JIT_CONFIGURATION")
        assert(info.lua52compat == (configuration == "lua52compat"))
        local wide_gc = runtime_arch == "x86_64" or runtime_arch == "arm64"
        assert(info.gc64 == (wide_gc and configuration ~= "nogc64"))
    end
    local mismatch = {}
    for key, value in pairs(info) do mismatch[key] = value end
    mismatch.runtime_version = "LuaJIT 2.1.mismatched"
    assert(not pcall(assert((loadstring or load)(lua_abi.checkSource(mismatch)))))
    local official = { version="Lua 5.1", major=5, minor=1, num=501, abi="lua5.1", kind="lua" }
    assert(not pcall(assert((loadstring or load)(lua_abi.checkSource(official)))))
    jit.off()
    assert(check(), "turning JIT off must not change runtime identity")
    jit.on()
end
print("LuaJIT runtime identity boundaries ok")
