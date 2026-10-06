--[[
Synchronize the installed Windows helper source with its C implementation.

Author:
    WaterRun
File:
    generate-windows-host-source.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

local input = assert(io.open("src/host/windows_host.c", "rb"))
local source = assert(input:read("*a"))
assert(input:close())
assert(not source:find("]====]", 1, true))
local output = assert(io.open("src/windows_host_source.lua", "wb"))
assert(output:write([=[--[[
Embedded XP-compatible Windows host implementation.

Author:
    WaterRun
File:
    windows_host_source.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

]=], "return [====[\n", source, "]====]\n"))
assert(output:close())
