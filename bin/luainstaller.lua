#!/usr/bin/env lua
--[[
Source and standalone entry point for the subcommand CLI.

Author:
    WaterRun
File:
    luainstaller.lua
Date:
    2026-09-22
Updated:
    2026-09-22
]]

local directory = (arg[0]:match("^(.*[/\\])") or "./")
package.loaded.luainstaller = dofile(directory .. "../luainstaller.lua")
os.exit(require("luainstaller.cli").main(arg, { program_name = "luainstaller" }) or 0)
