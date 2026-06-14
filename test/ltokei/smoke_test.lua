--[[
Smoke test for the ltokei source statistics sample.

The test validates recursive directory scanning, language detection, blank /
comment / code line classification, summary totals, and the CLI table output.

Author:
    WaterRun
File:
    smoke_test.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local ROOT = "test/ltokei"
package.path = ROOT .. "/src/?.lua;" .. package.path

local scanner = require("ltokei.scanner")
local formatter = require("ltokei.formatter")

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected text to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
    end
end

local report = assert(scanner.scan(ROOT .. "/fixtures"))
assert(report.total.files == 3, "expected three supported fixture files")
assert(report.languages.Lua.files == 1, "expected one Lua file")
assert(report.languages.Markdown.files == 1, "expected one Markdown file")
assert(report.languages.C.files == 1, "expected one C file")
assert(report.total.lines == 31, "expected fixture line total")
assert(report.total.comments == 17, "expected fixture comment total")
assert(report.total.blanks == 5, "expected fixture blank total")
assert(report.total.code == 9, "expected fixture code total")

local table_text = formatter.render(report)
assert_contains(table_text, "Language")
assert_contains(table_text, "Markdown")
assert_contains(table_text, "Total")

local cmd = "lua " .. shell_quote(ROOT .. "/main.lua") .. " " .. shell_quote(ROOT .. "/fixtures")
local pipe = assert(io.popen(cmd .. " 2>&1", "r"))
local out = pipe:read("*a")
local ok = pipe:close()
if not ok then
    error("command failed: " .. cmd .. "\n" .. out, 2)
end
assert_contains(out, "Lua")
assert_contains(out, "Total")

print("ltokei smoke test passed")
