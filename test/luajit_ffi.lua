--[[
Explicit FFI libraries survive source removal and select extract mode.

Author:
    WaterRun
File:
    luajit_ffi.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
assert(type(jit) == "table", "run this suite with LuaJIT 2.1")
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local root = assert(fs.makePrivateDirectory("luajit-ffi"))
local success, failure = pcall(function()
    local ffi = require("ffi")
    local original_load = ffi.load
    local cgen = require("luainstaller.cgen")
    local embedded = assert((loadstring or load)(cgen.runtimeSource .. "\nreturn {run=run, install=install}"))()
    for _, runtime in ipairs({require("luainstaller.runtime"), embedded}) do
        local payload = {entry={source="error('ffi-run-failure')"},
            ffi_libraries={fixture={path="unused.so"}}}
        local ran = pcall(runtime.run, payload)
        assert(not ran and ffi.load == original_load, "failed application leaked its ffi.load binding")
        local insert = table.insert
        table.insert = function() error("fixture searcher insertion failure") end
        local installed = pcall(runtime.install, payload)
        table.insert = insert
        assert(not installed and ffi.load == original_load, "failed install leaked its ffi.load binding")
    end
    local native, err = toolchain.resolve()
    assert(native, err and err.error.message)
    local source = path.join(root, "example.c")
    local library_dir = path.join(root, "shared libraries")
    assert(fs.makeDirectory(library_dir))
    local library = path.join(library_dir, "ffi-example." .. toolchain.nativeModuleExtension(native))
    assert(fs.writeFile(source, [[
#if defined(_WIN32)
__declspec(dllexport)
#endif
int luai_ffi_add(int a, int b) { return a + b; }
]]))
    local compiled, output = toolchain.compileNativeModule(native, source, library, {work_dir=root})
    assert(compiled, output)
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, [[
local ffi = require("ffi")
ffi.cdef("int luai_ffi_add(int, int);")
local lib = ffi.load("luai_test_example", true)
assert(lib.luai_ffi_add(21, 21) == 42)
assert(ffi.load("luai_test_alias").luai_ffi_add(1, 2) == 3)
print("ffi-library-ok")
]]))
    local libraries = {luai_test_example=library, luai_test_alias=library}
    for _, invalid in ipairs({false, "library", {[1]=library}, {["../bad"]=library},
        {valid="bad\0path"}, {valid=42}}) do
        local rejected = api.analyze({entry=entry, ffi_libraries=invalid})
        assert(not rejected.ok and rejected.error.type == "InvalidOptionsError")
    end
    local limited = api.analyze({entry=entry, ffi_libraries=libraries, max_bundle_bytes=1024})
    assert(not limited.ok and limited.error.type == "ResourceLimitExceededError")
    local too_many = api.analyze({entry=entry, ffi_libraries=libraries, max_deps=1})
    assert(not too_many.ok and too_many.error.type == "DependencyLimitExceededError")
    local analyzed = api.analyze({entry=entry, ffi_libraries=libraries})
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    assert(#analyzed.dependencies.libraries == 1)
    local runtime = api.analyze({entry=entry, ffi_libraries=libraries, discovery_mode="runtime"})
    assert(runtime.ok, runtime.error and (runtime.error.message .. "\n" .. tostring(runtime.error.output)))
    local rejected = api.bundle({entry=entry, ffi_libraries=libraries, mode="onefile",
        onefile_mode="no-extract", out=path.join(root, "rejected")})
    assert(not rejected.ok and rejected.error.type == "UnsupportedOnefileModeError")
    assert(fs.pathType(path.join(root, "rejected")) == "missing")
    local outputs = {}
    for _, cli in ipairs({{"bin/luai.lua", "-b"}, {"bin/luainstaller.lua", "build"}}) do
        local out = path.join(root, cli[2] == "-b" and "compact-cli" or "modern-cli")
        local built, diagnostic = process.outputCommand(harness.lua_command(), {
            cli[1], cli[2], entry, "--ffi-library", "luai_test_example=" .. library,
            "--ffi-library", "luai_test_alias=" .. library, "-o", out,
        })
        assert(built, diagnostic)
        outputs[#outputs + 1] = path.join(out, path.basename(out) .. native.executable_suffix)
        local duplicate = process.outputCommand(harness.lua_command(), {
            cli[1], cli[2], entry, "--ffi-library", "same=" .. library,
            "--ffi-library", "same=" .. library, "-o", path.join(root, "duplicate"),
        })
        assert(not duplicate and fs.pathType(path.join(root, "duplicate")) == "missing")
    end
    for _, mode in ipairs({"onedir", "extract", "auto"}) do
        local built = api.bundle({entry=entry, ffi_libraries=libraries,
            mode=mode == "onedir" and "onedir" or "onefile",
            onefile_mode=mode == "onedir" and "auto" or mode,
            out=path.join(root, "ffi-" .. mode)})
        assert(built.ok, built.error and (built.error.message .. "\n" .. tostring(built.error.output)))
        if mode ~= "onedir" then assert(built.onefile_mode == "extract") end
        outputs[#outputs + 1] = built.executable
    end
    assert(fs.removeFile(entry))
    assert(fs.removeFile(library))
    for _, executable in ipairs(outputs) do
        local ran, output = process.outputCommand(executable, {}, {PATH="", LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("ffi-library-ok", 1, true), output)
    end
end)
assert(fs.removeTree(root))
assert(success, tostring(failure))
print("LuaJIT explicit FFI libraries ok")
