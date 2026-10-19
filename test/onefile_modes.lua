--[[
Single-file selection keeps pure Lua in memory and native modules extractable.

Author:
    WaterRun
File:
    onefile_modes.lua
Date:
    2026-10-12
Updated:
    2026-10-20
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local root = assert(fs.makePrivateDirectory("onefile-modes"))
local called, failure = pcall(function()
    assert(api.ErrorTypes.STATIC_LUA_UNAVAILABLE == "StaticLuaUnavailableError",
        "the public error registry omits unavailable static Lua")
    assert(api.ErrorTypes.UNSUPPORTED_ONEFILE_MODE == "UnsupportedOnefileModeError",
        "the public error registry omits unsupported single-file mode")
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, "assert(arg[1]=='literal & % arg'); print('direct-pure-lua')\n"))
    for _, mode in ipairs({"no-extract", "auto", "extract"}) do
        local built = api.bundle({entry=entry, mode="onefile", onefile_mode=mode,
            out=path.join(root, "app-" .. mode)})
        assert(built.ok, built.error and built.error.message)
        assert(built.onefile_mode == (mode == "auto" and "no-extract" or mode))
        assert(type(built.selection_reason) == "string" and built.selection_reason ~= "",
            "single-file selection did not explain its choice")
        local ran, output = process.outputCommand(built.executable, {"literal & % arg"}, {
            PATH="", LUA_PATH="", LUA_CPATH="", TMPDIR=path.join(root, "missing-temp"),
        })
        if mode ~= "extract" then
            assert(ran and output:find("direct-pure-lua", 1, true), output)
            assert(fs.pathType(path.join(root, "missing-temp")) == "missing")
        end
        local exported = path.join(root, "materials-" .. mode)
        assert(fs.makeDirectory(exported))
        local exported_ok, export_output = process.outputCommand(built.executable,
            {"--luainstaller-extract", exported})
        assert(exported_ok, export_output)
        exported = export_output:match("^%s*(.-)%s*$")
        assert(fs.pathType(path.join(exported, ".luai/build/launcher.c")) == "file")
        assert(fs.pathType(path.join(exported, ".luai/build/RELINKING.adoc")) == "file")
        if mode == "no-extract" then
            local launcher = path.join(exported, ".luai/build/launcher.c")
            local edited = assert(fs.readFile(launcher)) .. "\n/* user relinking edit */\n"
            assert(fs.writeFile(launcher, edited))
            local repeated = process.outputCommand(built.executable, {"--luainstaller-extract",
                path.join(root, "materials-" .. mode)})
            assert(not repeated, "material export overwrote an existing exported tree")
            assert(fs.readFile(launcher) == edited, "repeat export changed edited relinking source")
            local target, link = path.join(root, "export-target"), path.join(root, "export-link")
            assert(fs.makeDirectory(target))
            if package.config:sub(1, 1) == "\\" then
                local fixture = dofile("test/support/windows_fixture.lua")(root)
                local linked, link_output = process.outputCommand(fixture, {"junction", link, target})
                assert(linked, link_output)
            else
                assert(process.outputCommand("ln", {"-s", target, link}))
            end
            local unsafe_export = process.outputCommand(built.executable, {"--luainstaller-extract", link})
            assert(not unsafe_export, "material export followed a linked destination")
            assert(#assert(fs.listTree(target)) == 0, "refused export wrote through a linked destination")
            assert(fs.removeFile(link))
            local relink_materials = path.join(root, "relinking-input")
            local relocated, relocation_error = fs.rename(exported, relink_materials)
            assert(relocated, relocation_error)
            exported = relink_materials
            local regenerated, regeneration_output = process.outputCommand(harness.lua_command(), {
                ".luai/build/generate-onefile-payload.lua", ".", ".luai/build/payload.inc",
            }, {}, {timeout_seconds=120, working_directory=exported})
            assert(regenerated, regeneration_output)
            local static, static_error = toolchain.resolve({require_static=true})
            assert(static, static_error and static_error.error.message)
            if package.config:sub(1, 1) == "\\" then
                static.link_args[#static.link_args + 1] = static.compiler_family == "msvc"
                    and "advapi32.lib" or "-ladvapi32"
            end
            local relinked = path.join(root, "relinked" .. (package.config:sub(1, 1) == "\\" and ".exe" or ""))
            local linked, link_output = toolchain.compile(static, path.join(exported, ".luai/build/no-extract.c"),
                relinked, {work_dir=path.join(exported, ".luai/build")})
            assert(linked, link_output)
            local relink_ran, relink_output = process.outputCommand(relinked, {"literal & % arg"}, {
                PATH="", LUA_PATH="", LUA_CPATH="", TMPDIR=path.join(root, "missing-temp"),
            })
            assert(relink_ran and relink_output:find("direct-pure-lua", 1, true), relink_output)
        end
    end
    local native, native_error = toolchain.resolve()
    assert(native, native_error and native_error.error.message)
    if native.link_mode == "shared" then
        local prefix = path.join(root, "shared-only")
        assert(fs.makeDirectory(path.join(prefix, "lib")))
        assert(fs.writeFile(path.join(prefix, "lib/" .. path.basename(native.library_path)),
            assert(fs.readFile(native.library_path))))
        local runtime_name = native.runtime_name or path.basename(native.runtime_path)
        assert(fs.copyFile(native.runtime_path, path.join(prefix, runtime_name)))
        if package.config:sub(1, 1) ~= "\\" then
            local runtime_copy = path.join(prefix, "lib/" .. runtime_name)
            if fs.pathType(runtime_copy) == "missing" then
                assert(fs.copyFile(native.runtime_path, runtime_copy))
            else
                assert(fs.readFile(runtime_copy) == fs.readFile(native.runtime_path),
                    "shared-only fixture has different runtime bytes at the same filename")
            end
        end
        local automatic = api.bundle({entry=entry, mode="onefile", lua_prefix=prefix,
            out=path.join(root, "shared-auto")})
        assert(automatic.ok, automatic.error and automatic.error.message)
        assert(automatic.onefile_mode == "extract" and automatic.selection_reason == "static-lua-unavailable")
        local ran, output = process.outputCommand(automatic.executable, {"literal & % arg"},
            {LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("direct-pure-lua", 1, true), output)
        local rejected = api.bundle({entry=entry, mode="onefile", onefile_mode="no-extract",
            lua_prefix=prefix, out=path.join(root, "shared-rejected")})
        assert(not rejected.ok and rejected.error.type == "StaticLuaUnavailableError")
        assert(fs.pathType(path.join(root, "shared-rejected")) == "missing")
    end
    local compile = toolchain.compile
    local application_attempts = 0
    toolchain.compile = function(config, source, ...)
        if path.basename(source) == "launcher.c" then
            application_attempts = application_attempts + 1
            return false, "injected application compilation failure", "fixture-compiler"
        end
        return compile(config, source, ...)
    end
    local rejected = api.bundle({entry=entry, mode="onefile", out=path.join(root, "compile-rejected")})
    toolchain.compile = compile
    assert(not rejected.ok and rejected.error.type == "CompilationFailedError")
    assert(application_attempts == 1, "auto retried a failed application compilation in another mode")
    assert(fs.pathType(path.join(root, "compile-rejected")) == "missing")
    assert(fs.writeFile(entry, "os.exit(37)\n"))
    local exiting = api.bundle({entry=entry, mode="onefile", onefile_mode="no-extract",
        out=path.join(root, "exit37")})
    assert(exiting.ok, exiting.error and exiting.error.message)
    local ran, _, status = process.outputCommand(exiting.executable, {}, {PATH="", LUA_PATH="", LUA_CPATH=""})
    assert(not ran and status and status.code == 37, "direct startup did not preserve the application exit code")
end)
local export_link = path.join(root, "export-link")
if fs.pathType(export_link) == "reparse" then assert(fs.removeFile(export_link)) end
assert(fs.removeTree(root))
assert(called, failure)
print("single-file modes ok")
