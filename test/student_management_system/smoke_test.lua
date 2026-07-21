--[[
Smoke test for the student management system sample.

This script exercises the command-mode interface so the sample can be checked
without interactive input.

Author:
    WaterRun
File:
    smoke_test.lua
Date:
    2026-06-14
Updated:
    2026-07-18
]]
local ROOT = "test/student_management_system"
local harness = dofile("test/support/harness.lua")
local DATA = os.tmpname() .. ".json"
local EXPORT = os.tmpname() .. ".csv"
local IMPORT = os.tmpname() .. ".import.csv"

local function run(arguments)
    local command_arguments = {
        ROOT .. "/main.lua",
        "--data",
        DATA,
    }
    for _, argument in ipairs(arguments) do
        command_arguments[#command_arguments + 1] = argument
    end
    return harness.run(harness.command(harness.lua_command(), command_arguments))
end

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected output to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
    end
end

local function write_file(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

local function check_windows_replace_semantics()
    package.path = ROOT .. "/?.lua;" .. package.path
    local storage = require("storage")
    local path = os.tmpname() .. ".windows-replace.json"
    write_file(path, '{"version":1,"next_id":1,"students":[]}\n')

    local original_rename = os.rename
    os.rename = function(src, dst)
        if dst == path then
            local existing = io.open(dst, "rb")
            if existing then
                existing:close()
                return nil, "File exists"
            end
        end
        return original_rename(src, dst)
    end

    local ok, err = pcall(function()
        storage.save(path, {
            version = 1,
            next_id = 2,
            students = {
                { id = 1, name = "Ada Lovelace" },
            },
        })
    end)
    os.rename = original_rename
    os.remove(path)
    os.remove(path .. ".tmp")
    if not ok then
        error(err, 2)
    end

    write_file(path, '{"version":1,"next_id":1,"students":[]}\n')
    local calls = 0
    os.rename = function(src, dst)
        if src == path .. ".tmp" and dst == path then
            calls = calls + 1
            return nil, calls == 1 and "File exists" or "replacement failed"
        end
        return original_rename(src, dst)
    end
    local replace_ok = pcall(function()
        storage.save(path, {
            version = 1,
            next_id = 3,
            students = {
                { id = 2, name = "Grace Hopper" },
            },
        })
    end)
    os.rename = original_rename
    local file = io.open(path, "rb")
    local preserved = file and (file:read("*a") or "") or nil
    if file then
        file:close()
    end
    os.remove(path)
    os.remove(path .. ".tmp")
    if replace_ok then
        error("forced replacement failure should not succeed", 2)
    end
    if preserved ~= '{"version":1,"next_id":1,"students":[]}\n' then
        error("failed replacement must preserve the original storage file", 2)
    end
end

os.remove(DATA)
os.remove(EXPORT)
os.remove(IMPORT)

check_windows_replace_semantics()

assert_contains(run({ "seed" }), "Seeded 8 students")
assert_contains(run({ "list", "--sort", "average" }), "Ada Lovelace")
assert_contains(run({ "search", "--name", "ada" }), "Ada Lovelace")
assert_contains(run({ "report" }), "Class Summary")
assert_contains(run({
    "add", "--name", "Ivy Chen", "--gender", "F", "--class", "CS2",
    "--birth", "2004", "--phone", "5550109", "--email", "ivy@example.test",
    "--grades", "lua=96,python=91,math=93,english=88",
}), "Added student")
assert_contains(run({ "rank", "--course", "lua" }), "Lua Ranking")
assert_contains(run({ "export", "--out", EXPORT }), "Exported")

write_file(IMPORT, "name,gender,class,birth_year,phone,email,lua,python,math,english\nKai Zhang,M,CS3,2003,5550110,kai@example.test,77,81,86,79\n")
assert_contains(run({ "import", "--file", IMPORT }), "Imported 1 students")
assert_contains(run({ "stats" }), "Total students: 10")

os.remove(DATA)
os.remove(EXPORT)
os.remove(IMPORT)

print("student_management_system smoke test passed")
