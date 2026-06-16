--[[
Comprehensive smoke and audit runner for the luainstaller test samples.

Author:
    WaterRun
File:
    smoke_all.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

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

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected output to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
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
    local out = run("find test -type f -name '*.lua' | sort")
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
    local whitespace = run("rg -n '\\t|[ \\t]+$|\\r$' test || true")
    if whitespace ~= "" then
        error("whitespace style violations:\n" .. whitespace, 2)
    end
end

local function check_syntax()
    run("find test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p")
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
    local script = [[
local analyzer = dofile("src/analyzer.lua")
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
    local script = [[
package.preload["luainstaller.analyzer"] = function() return dofile("src/analyzer.lua") end
package.preload["luainstaller.logger"] = function() return dofile("src/logger.lua") end
package.preload["luainstaller"] = function() return dofile("src/init.lua") end
local luainstaller = require("luainstaller")

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

local bundled = luainstaller.bundle({
    entry = "test/student_management_system/main.lua",
    mode = "onedir",
    out = "build/student-manager",
    max_deps = 250,
})
assert(bundled.ok == false)
assert(bundled.error.type == "NotImplementedError")

local missing = luainstaller.analyze({ entry = "test/no-such-file.lua" })
assert(missing.ok == false)
assert(missing.error.type == "ScriptNotFoundError")

print("api contract ok")
]]
    assert_contains(run("lua -e " .. shell_quote(script)), "api contract ok")
end

check_style()
check_syntax()
check_samples()
check_analyzer_visibility()
check_api_contract()

print("all packaging-target samples passed comprehensive smoke audit")
