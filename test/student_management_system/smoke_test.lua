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
    2026-06-14
]]
local ROOT = "test/student_management_system"
local DATA = os.tmpname() .. ".json"
local EXPORT = os.tmpname() .. ".csv"
local IMPORT = os.tmpname() .. ".import.csv"

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run(args)
    local cmd = table.concat({
        "lua",
        shell_quote(ROOT .. "/main.lua"),
        "--data",
        shell_quote(DATA),
        args,
    }, " ")
    local pipe = assert(io.popen(cmd .. " 2>&1", "r"))
    local out = pipe:read("*a")
    local ok = pipe:close()
    if not ok then
        error("command failed: " .. cmd .. "\n" .. out, 2)
    end
    return out
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

os.remove(DATA)
os.remove(EXPORT)
os.remove(IMPORT)

assert_contains(run("seed"), "Seeded 8 students")
assert_contains(run("list --sort average"), "Ada Lovelace")
assert_contains(run("search --name ada"), "Ada Lovelace")
assert_contains(run("report"), "Class Summary")
assert_contains(run("add --name 'Ivy Chen' --gender F --class CS2 --birth 2004 --phone 5550109 --email ivy@example.test --grades lua=96,python=91,math=93,english=88"), "Added student")
assert_contains(run("rank --course lua"), "Lua Ranking")
assert_contains(run("export --out " .. shell_quote(EXPORT)), "Exported")

write_file(IMPORT, "name,gender,class,birth_year,phone,email,lua,python,math,english\nKai Zhang,M,CS3,2003,5550110,kai@example.test,77,81,86,79\n")
assert_contains(run("import --file " .. shell_quote(IMPORT)), "Imported 1 students")
assert_contains(run("stats"), "Total students: 10")

os.remove(DATA)
os.remove(EXPORT)
os.remove(IMPORT)

print("student_management_system smoke test passed")
