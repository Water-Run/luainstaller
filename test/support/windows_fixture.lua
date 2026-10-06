--[[
Compile the native Windows integration-test driver.

Author:
    WaterRun
File:
    windows_fixture.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

return function(root)
    local toolchain = require("luainstaller.toolchain")
    local path = require("luainstaller.path")
    local compiler, err = toolchain.resolveCompiler({})
    assert(compiler, err and err.error.message)
    local executable = path.join(root, "windows-test-driver.exe")
    local ok, output = toolchain.compileStandalone(compiler,
        path.absolute("test/fixtures/windows_host_probe.c"), executable, { work_dir = root })
    assert(ok, output)
    return executable
end
