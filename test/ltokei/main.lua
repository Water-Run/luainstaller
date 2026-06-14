#!/usr/bin/env lua
--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]

local ROOT = debug.getinfo(1, "S").source:sub(2):match("^(.*)/main%.lua$") or "."
package.path = ROOT .. "/src/?.lua;" .. package.path

local scanner = require("ltokei.scanner")
local formatter = require("ltokei.formatter")

local target = (arg and arg[1]) or "."
local report, err = scanner.scan(target)
if not report then
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end

print(formatter.render(report))
