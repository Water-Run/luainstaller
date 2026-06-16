--[[
Runtime bundle entry fixture.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local greeter = require("greeter")
print(greeter.message(arg[1] or "runtime"))
print("entry=" .. tostring(arg[0]))
