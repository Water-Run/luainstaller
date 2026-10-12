--[[
Synchronize the installed POSIX supervisor source with its C implementation.

Author:
    WaterRun
File:
    generate-posix-host-source.lua
Date:
    2026-10-12
Updated:
    2026-10-12
]]

local input = assert(io.open("src/host/posix_host.c", "rb"))
local source = assert(input:read("*a"))
assert(input:close())
assert(not source:find("]====]", 1, true))
local output = assert(io.open("src/posix_host_source.lua", "wb"))
assert(output:write([=[--[[
Embedded POSIX process supervisor implementation.

Author:
    WaterRun
File:
    posix_host_source.lua
Date:
    2026-10-12
Updated:
    2026-10-12
]]

]=], "return [====[\n", source, "]====]\n"))
assert(output:close())
