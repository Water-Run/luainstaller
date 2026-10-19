--[[
Recovery at the directory publication and backup cleanup boundaries.

Author:
    WaterRun
File:
    output_transaction.lua
Date:
    2026-10-12
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local api = require("luainstaller")
local root = assert(fs.makePrivateDirectory("output-transaction"))
local driver = path.join(root, "driver.lua")
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
-- Older ABIs need time to verify libraries, backups and native bootstrap
-- inventories. The fault must be reached before the bounded driver stops.
local driver_timeout = (_VERSION == "Lua 5.1" or _VERSION == "Lua 5.2") and 600 or 120
local phases = { "before-backup", "after-backup", "after-publish", "during-cleanup",
    "during-quarantine", "after-marker", "during-directory-cleanup" }
local diagnostic_phase = os.getenv("LUAI_TEST_PUBLICATION_PHASE")
if diagnostic_phase then
    local valid
    for _, phase in ipairs(phases) do if phase == diagnostic_phase then valid = true end end
    assert(valid, "unknown diagnostic publication phase")
    phases = {diagnostic_phase}
end

assert(fs.writeFile(driver, [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local phase, entry, out = arg[1], arg[2], arg[3]
local backup, marker_quarantine
local function stop()
    io.stdout:write("fault-injected:" .. phase .. "\n")
    io.stdout:flush()
    os.exit(86)
end
local function renamed(original, source, destination)
    if source == out and phase == "before-backup" then stop() end
    local ok, err = original(source, destination)
    if ok and source == out then
        backup = destination
        if phase == "after-backup" then stop() end
    end
    if ok and destination == out and phase == "after-publish" then stop() end
    if ok and destination == out and phase == "interrupt-recovery" then stop() end
    if ok and backup and source:sub(1, #backup + 1) == backup .. "/"
        and destination:match("/%.luai%-[^/]+$") then
        if source:match("/%.luai/generated%-output%.txt$") then marker_quarantine = destination end
        if phase == "during-quarantine" then stop() end
    end
    return ok, err
end
local original_rename, original_fs_rename = os.rename, fs.rename
os.rename = function(source, destination) return renamed(original_rename, source, destination) end
fs.rename = function(source, destination) return renamed(original_fs_rename, source, destination) end
local original_remove = fs.removeFile
fs.removeFile = function(candidate)
    local ok, err = original_remove(candidate)
    if ok and phase == "during-cleanup" and backup
        and candidate:sub(1, #backup + 1) == backup .. "/" then stop() end
    if ok and phase == "after-marker" and candidate == marker_quarantine then stop() end
    return ok, err
end
local original_rmdir = fs.removeDirectory
fs.removeDirectory = function(candidate)
    local ok, err = original_rmdir(candidate)
    if ok and phase == "during-directory-cleanup" and backup
        and candidate:sub(1, #backup + 1) == backup .. "/" then stop() end
    return ok, err
end
if phase == "recover-with-failed-build" then
    local toolchain = require("luainstaller.toolchain")
    local original_compile = toolchain.compile
    toolchain.compile = function(config, source, output, options)
        if source:match("/launcher%.c$") then
            return false, "injected launcher compilation failure", "injected-compiler"
        end
        return original_compile(config, source, output, options)
    end
end
local built = api.bundle({entry=entry, out=out, mode="onedir"})
if phase == "recover-only" then
        assert(not built.ok and (built.error.type == "ScriptNotFoundError"
        or built.error.type == "FilesystemError"), "unexpected recovery result: "
            .. tostring(built.error and built.error.message)
            .. " cause=" .. tostring(built.error and built.error.cause))
    print("recovery-result:" .. built.error.type)
    return
end
if phase == "recover-with-failed-build" then
    assert(not built.ok and built.error.type == "CompilationFailedError",
        built.error and built.error.message or "failure injection did not run")
    print("recovery reached the new build")
else
    error("publication fault was not reached: " .. phase)
end
]]))

local function runDriver(arguments)
    if package.config:sub(1, 1) == "\\" then
        local ok, output, status = require("luainstaller.windows_host").execute(
            harness.lua_command(), arguments, {}, driver_timeout)
        return ok, tostring(output or ""):gsub("\r\n", "\n"), status
    end
    return process.outputCommand(harness.lua_command(), arguments, {}, {timeout_seconds=driver_timeout})
end

local called, failure = xpcall(function()
    for _, phase in ipairs(phases) do
        local directory = path.join(root, phase)
        assert(fs.makeDirectory(directory))
        local entry = path.join(directory, "main.lua")
        local out = path.join(directory, "app")
        assert(fs.writeFile(entry, "print('old-generation')\n"))
        local built = api.bundle({entry=entry, out=out, mode="onedir"})
        assert(built.ok, built.error and built.error.message)
        assert(fs.writeFile(entry, "print('new-generation')\n"))
        local survived, output = runDriver({
            driver, phase, entry, out,
        })
        assert(not survived, "faulted build returned success: " .. tostring(output))
        assert(output:find("fault-injected:" .. phase, 1, true),
            "fault boundary was not reached within the driver budget: " .. phase .. "\n" .. output)
        local recovered, recovery_output, recovery_status = runDriver({
            driver, "recover-with-failed-build", entry, out,
        })
        assert(recovered, "recovery driver failed: phase=" .. phase
            .. " status=" .. tostring(recovery_status) .. "\n" .. tostring(recovery_output))
        local ran, result = process.outputCommand(path.join(out, "app" .. suffix), {}, {
            LUA_PATH="", LUA_CPATH="",
        })
        local expected = (phase == "before-backup" or phase == "after-backup")
            and "old-generation" or "new-generation"
        assert(ran and result:find(expected, 1, true),
            phase .. " did not preserve the published generation: " .. tostring(result))
        for _, item in ipairs(assert(fs.listTree(directory))) do
            if not item.path:find("/", 1, true) then
                assert(not item.path:find(".luai-", 1, true),
                    phase .. " left unrecovered transaction data: " .. item.path)
            end
        end
        print("output transaction recovered: " .. phase)
    end
    if diagnostic_phase then
        print("diagnostic publication phase only: " .. diagnostic_phase)
        return
    end
    local directory = path.join(root, "missing-source")
    assert(fs.makeDirectory(directory))
    local entry, out = path.join(directory, "main.lua"), path.join(directory, "app")
    assert(fs.writeFile(entry, "print('old-generation')\n"))
    local initial = api.bundle({entry=entry, out=out})
    assert(initial.ok, initial.error and initial.error.message)
    local survived, fault_output, fault_status = runDriver({driver, "after-backup", entry, out})
    assert(not survived and fault_output:find("fault-injected:after-backup", 1, true),
        "fault driver status=" .. tostring(fault_status and fault_status.code)
            .. ": " .. tostring(fault_output))
    local failed = api.bundle({entry=entry .. ".missing", out=out})
    assert(not failed.ok and failed.error.type == "ScriptNotFoundError")
    local ran, output = process.outputCommand(initial.executable, {}, {LUA_PATH="", LUA_CPATH=""})
    assert(ran and output:find("old-generation", 1, true),
        "missing build input prevented restoration of the previous output: " .. tostring(output))

    directory = path.join(root, "recovery-interrupted")
    assert(fs.makeDirectory(directory))
    entry, out = path.join(directory, "main.lua"), path.join(directory, "app")
    assert(fs.writeFile(entry, "print('old-generation')\n"))
    initial = api.bundle({entry=entry, out=out})
    assert(initial.ok, initial.error and initial.error.message)
    assert(not runDriver({driver, "after-backup", entry, out}))
    assert(not runDriver({
        driver, "interrupt-recovery", entry .. ".missing", out,
    }))
    failed = api.bundle({entry=entry .. ".missing", out=out})
    assert(not failed.ok and failed.error.type == "ScriptNotFoundError",
        failed.error and failed.error.message)
    ran, output = process.outputCommand(initial.executable, {}, {LUA_PATH="", LUA_CPATH=""})
    assert(ran and output:find("old-generation", 1, true), output)
    print("output transaction recovered after recovery was interrupted")

    for _, injected in ipairs({"throw", "user-content"}) do
        directory = path.join(root, injected)
        assert(fs.makeDirectory(directory))
        entry, out = path.join(directory, "main.lua"), path.join(directory, "app")
        assert(fs.writeFile(entry, "print('old-generation')\n"))
        initial = api.bundle({entry=entry, out=out})
        assert(initial.ok, initial.error and initial.error.message)
        local phase = injected == "throw" and "after-backup" or "after-publish"
        local survived, fault_output = runDriver({driver, phase, entry, out})
        assert(not survived and fault_output:find("fault-injected:" .. phase, 1, true), fault_output)
        local user_file
        if injected == "throw" then
            local rename = fs.rename
            fs.rename = function(source, destination)
                if destination == out then
                    error("injected recovery exception")
                end
                return rename(source, destination)
            end
            failed = api.bundle({entry=entry .. ".missing", out=out})
            fs.rename = rename
        else
            for _, item in ipairs(assert(fs.listTree(directory))) do
                local candidate = path.join(directory, item.path)
                if not item.path:find("/", 1, true) and item.type == "directory"
                    and item.path:match("^%.luai%-")
                    and fs.pathType(path.join(candidate, ".luai/generated-output.txt")) == "file" then
                    user_file = path.join(candidate, "USER.txt")
                end
            end
            assert(user_file, "backup fixture was not found")
            assert(fs.writeFile(user_file, "user content must survive\n"))
            failed = api.bundle({entry=entry .. ".missing", out=out})
            assert(fs.readRegularFile(user_file) == "user content must survive\n")
            assert(fs.removeFile(user_file))
        end
        assert(not failed.ok and failed.error.type == "FilesystemError", "failed recovery returned success")
        failed = api.bundle({entry=entry .. ".missing", out=out})
        assert(not failed.ok and failed.error.type == "ScriptNotFoundError",
            failed.error and failed.error.message)
        print("output transaction safely retried after " .. injected)
    end

    if package.config:sub(1, 1) == "/" then
        directory = path.join(root, "concurrent")
        assert(fs.makeDirectory(directory))
        entry, out = path.join(directory, "main.lua"), path.join(directory, "app")
        assert(fs.writeFile(entry, "print('old-generation')\n"))
        initial = api.bundle({entry=entry, out=out})
        assert(initial.ok, initial.error and initial.error.message)
        local survived, fault_output = runDriver({driver, "after-backup", entry, out})
        assert(not survived and fault_output:find("fault-injected:after-backup", 1, true), fault_output)
        local command = assert(process.command(harness.lua_command(), {driver, "recover-only", entry .. ".missing", out}))
        local concurrent, concurrency_output = process.output(command .. " & p=$!; " .. command
            .. "; s=$?; wait \"$p\"; t=$?; test \"$s\" -eq 0 && test \"$t\" -eq 0", {timeout_seconds=driver_timeout})
        assert(concurrent, concurrency_output)
        failed = api.bundle({entry=entry .. ".missing", out=out})
        assert(not failed.ok and failed.error.type == "ScriptNotFoundError", failed.error and failed.error.message)
        ran, output = process.outputCommand(initial.executable, {}, {LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("old-generation", 1, true), output)
        print("concurrent output recovery preserved the previous generation")
    end
end, function(err) return err end)
assert(fs.removeTree(root))
assert(called, failure)
print("output transaction recovery ok")
