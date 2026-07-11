--[[
Runtime bundle entry fixture.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-16
Updated:
    2026-07-11
]]

local entry_path = tostring(arg and arg[0] or "")
local entry_dir = entry_path:match("^(.*)[/\\][^/\\]+$")
local original_package_path = package.path
if entry_dir and entry_dir ~= "" then
    package.path = entry_dir .. "/?.lua;" .. entry_dir .. "/?/init.lua;" .. package.path
end

local loaded, greeter_or_error = pcall(function()
    return require("greeter")
end)
package.path = original_package_path
if not loaded then
    error(greeter_or_error, 0)
end
local greeter = greeter_or_error
print(greeter.message(arg[1] or "runtime"))
print("entry=" .. tostring(arg[0]))
