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
    2026-07-18
]]
local ROOT = "test/ltokei"
package.path = ROOT .. "/src/?.lua;" .. package.path
local harness = dofile("test/support/harness.lua")

local scanner = require("ltokei.scanner")
local formatter = require("ltokei.formatter")

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
assert(report.total.lines == 32, "expected fixture line total")
assert(report.total.comments == 17, "expected fixture comment total")
assert(report.total.blanks == 5, "expected fixture blank total")
assert(report.total.code == 10, "expected fixture code total")

local table_text = formatter.render(report)
assert_contains(table_text, "Language")
assert_contains(table_text, "Markdown")
assert_contains(table_text, "Total")

local cmd = harness.command(harness.lua_command(), {
    ROOT .. "/main.lua",
    ROOT .. "/fixtures",
})
local out = harness.run(cmd)
assert_contains(out, "Lua")
assert_contains(out, "Total")

print("ltokei smoke test passed")
