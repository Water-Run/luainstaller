local input = arg[1]
local output = arg[2]

if not input or not output then
    print("usage: lua 07_file_copy.lua <input> <output>")
    os.exit(0)
end

local src = assert(io.open(input, "rb"))
local data = src:read("*a")
src:close()

local dst = assert(io.open(output, "wb"))
dst:write(data)
dst:close()

print("copied " .. tostring(#data) .. " bytes")
