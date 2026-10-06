--[[
Regenerate payload.inc for an extracted luainstaller onefile bundle.

Usage:
    lua generate-onefile-payload.lua <extracted-root> [output]

The generated payload-files.lua is authoritative for path ordering and mode.

Author:
    WaterRun
File:
    generate-onefile-payload.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

local root = assert(arg and arg[1], "extracted bundle root is required")
local separator = package.config:sub(1, 1)
local windows = separator == "\\"

local function normalize(value)
    value = tostring(value or ""):gsub("\\", "/")
    local prefix = value:sub(1, 1) == "/" and "/" or ""
    local parts = {}
    for part in value:gmatch("[^/]+") do
        if part == ".." then
            assert(#parts > 0, "path escapes its root")
            parts[#parts] = nil
        elseif part ~= "" and part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return prefix .. table.concat(parts, "/")
end

local function safeRelative(value)
    value = tostring(value or ""):gsub("\\", "/")
    if value == "" or value:sub(1, 1) == "/" or value:sub(-1) == "/"
        or value:find("\0", 1, true) or value:find("//", 1, true)
        or value:match("^%a:") then
        return false
    end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return true
end

local function native(value)
    if windows then
        local converted = tostring(value):gsub("/", "\\")
        return converted
    end
    return value
end

local function join(left, right)
    return normalize(tostring(left):gsub("/+$", "") .. "/" .. tostring(right))
end

local function readFile(file_path)
    local handle, open_err = io.open(native(file_path), "rb")
    assert(handle, open_err)
    local content, read_err = handle:read("*a")
    local closed, close_err = handle:close()
    assert(content, read_err)
    assert(closed, close_err)
    return content
end

local function writeFile(file_path, content)
    local handle, open_err = io.open(native(file_path), "wb")
    assert(handle, open_err)
    local wrote, write_err = handle:write(content)
    local flushed, flush_err = handle:flush()
    local closed, close_err = handle:close()
    assert(wrote, write_err)
    assert(flushed, flush_err)
    assert(closed, close_err)
end

local function packU32(value)
    value = value % 4294967296
    local a = math.floor(value / 16777216) % 256
    local b = math.floor(value / 65536) % 256
    local c = math.floor(value / 256) % 256
    local d = value % 256
    return string.char(a, b, c, d)
end

local function quotePosix(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function portableDigest(content)
    -- Keep relinking usable when a legacy certutil cannot select SHA-256,
    -- or no external hash program is installed. Compression follows src/hash.lua.
    local modulus = 4294967296
    local function mask32(value) return value % modulus end
    local bits = rawget(_G, "bit32")
    if not bits and _VERSION:match("^Lua 5%.[345]$") then
        bits = assert((loadstring or load)([=[
return {
    band = function(a, b) return (a & b) & 0xffffffff end,
    bxor = function(a, b) return (a ~ b) & 0xffffffff end,
}
]=], "@payload-sha256-bits"))()
    end
    if not bits then
        local nibble_and, nibble_xor = {}, {}
        for left = 0, 15 do
            for right = 0, 15 do
                local a, b, both, different, place = left, right, 0, 0, 1
                for _ = 1, 4 do
                    local low_a, low_b = a % 2, b % 2
                    if low_a == 1 and low_b == 1 then both = both + place end
                    if low_a ~= low_b then different = different + place end
                    a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
                end
                local index = left * 16 + right + 1
                nibble_and[index], nibble_xor[index] = both, different
            end
        end
        local byte_and, byte_xor = {}, {}
        for left = 0, 255 do
            for right = 0, 255 do
                local low = (left % 16) * 16 + right % 16 + 1
                local high = math.floor(left / 16) * 16 + math.floor(right / 16) + 1
                local index = left * 256 + right + 1
                byte_and[index] = nibble_and[low] + nibble_and[high] * 16
                byte_xor[index] = nibble_xor[low] + nibble_xor[high] * 16
            end
        end
        local function bitOperation(lookup, left, right)
            local result, place = 0, 1
            for _ = 1, 4 do
                local a, b = left % 256, right % 256
                result = result + lookup[a * 256 + b + 1] * place
                left, right, place = (left - a) / 256, (right - b) / 256, place * 256
            end
            return result
        end
        bits = {
            band = function(a, b) return bitOperation(byte_and, a, b) end,
            bxor = function(a, b) return bitOperation(byte_xor, a, b) end,
        }
    end
    local band, bxor = bits.band, bits.bxor
    local function bnot(value) return modulus - 1 - value end
    local function rshift(value, count) return math.floor(value / 2 ^ count) end
    local function rotateRight(value, count)
        return rshift(value, count) + (value % 2 ^ count) * 2 ^ (32 - count)
    end
    local function wordAt(value, offset)
        local a, b, c, d = value:byte(offset, offset + 3)
        return a * 16777216 + b * 65536 + c * 256 + d
    end
    local SHA256_CONSTANTS = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    local function portableCompressBlock(state_hash, block, offset)
        offset = offset or 1
        local words = {}
        for index = 0, 15 do
            words[index] = wordAt(block, offset + index * 4)
        end
        for index = 16, 63 do
            local previous_15 = words[index - 15]
            local previous_2 = words[index - 2]
            local sigma0 = bxor(
                bxor(rotateRight(previous_15, 7), rotateRight(previous_15, 18)),
                rshift(previous_15, 3)
            )
            local sigma1 = bxor(
                bxor(rotateRight(previous_2, 17), rotateRight(previous_2, 19)),
                rshift(previous_2, 10)
            )
            words[index] = mask32(
                words[index - 16] + sigma0 + words[index - 7] + sigma1
            )
        end

        local a, b, c, d = state_hash[1], state_hash[2], state_hash[3], state_hash[4]
        local e, f, g, h = state_hash[5], state_hash[6], state_hash[7], state_hash[8]
        for index = 0, 63 do
            local sum1 = bxor(
                bxor(rotateRight(e, 6), rotateRight(e, 11)),
                rotateRight(e, 25)
            )
            local choose = bxor(band(e, f), band(bnot(e), g))
            local temporary1 = mask32(
                h + sum1 + choose + SHA256_CONSTANTS[index + 1] + words[index]
            )
            local sum0 = bxor(
                bxor(rotateRight(a, 2), rotateRight(a, 13)),
                rotateRight(a, 22)
            )
            local majority = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temporary2 = mask32(sum0 + majority)

            h = g
            g = f
            f = e
            e = mask32(d + temporary1)
            d = c
            c = b
            b = a
            a = mask32(temporary1 + temporary2)
        end

        state_hash[1] = mask32(state_hash[1] + a)
        state_hash[2] = mask32(state_hash[2] + b)
        state_hash[3] = mask32(state_hash[3] + c)
        state_hash[4] = mask32(state_hash[4] + d)
        state_hash[5] = mask32(state_hash[5] + e)
        state_hash[6] = mask32(state_hash[6] + f)
        state_hash[7] = mask32(state_hash[7] + g)
        state_hash[8] = mask32(state_hash[8] + h)
    end
    local state = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    local length = #content
    local padded = content .. "\128" .. string.rep("\0", (56 - (length + 1) % 64) % 64)
        .. packU32(math.floor(length / 536870912)) .. packU32((length % 536870912) * 8)
    for offset = 1, #padded, 64 do portableCompressBlock(state, padded, offset) end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        state[1], state[2], state[3], state[4], state[5], state[6], state[7], state[8])
end

local function commandDigest(file_path)
    local commands
    if windows then
        commands = {}
        if not file_path:find('["%%]') then
            commands[1] = 'certutil -hashfile "' .. native(file_path) .. '" SHA256 2>NUL'
        end
    else
        commands = {
            "sha256sum " .. quotePosix(file_path) .. " 2>/dev/null",
            "shasum -a 256 " .. quotePosix(file_path) .. " 2>/dev/null",
            "sha256 -q " .. quotePosix(file_path) .. " 2>/dev/null",
        }
    end
    for _, command in ipairs(commands) do
        local opened, pipe
        if type(io.popen) == "function" then opened, pipe = pcall(io.popen, command, "r") end
        if opened and pipe then
            local output = pipe:read("*a") or ""
            local ok = pipe:close()
            if ok then
                for digest in output:lower():gmatch("[%da-f]+") do
                    if #digest == 64 then return digest end
                end
            end
        end
    end
    return portableDigest(readFile(file_path))
end

local function cString(value)
    local escaped = {}
    value = tostring(value or "")
    for index = 1, #value do
        escaped[#escaped + 1] = string.format("\\%03o", value:byte(index))
    end
    return '"' .. table.concat(escaped) .. '"'
end

local function emitArray(index, content)
    local lines = {
        string.format("static const unsigned char luai_file_%d[] = {", index),
    }
    if #content == 0 then
        lines[#lines + 1] = "    0x00,"
    else
        for offset = 1, #content, 12 do
            local bytes = {}
            for position = offset, math.min(offset + 11, #content) do
                bytes[#bytes + 1] = string.format("0x%02x", content:byte(position))
            end
            lines[#lines + 1] = "    " .. table.concat(bytes, ", ") .. ","
        end
    end
    lines[#lines + 1] = "};"
    return table.concat(lines, "\n")
end

root = normalize(root)
local manifest_path = join(root, ".luai/build/payload-files.lua")
local manifest_chunk, load_err = loadfile(native(manifest_path))
assert(manifest_chunk, load_err)
local records = manifest_chunk()
assert(type(records) == "table", "payload manifest is not a table")

local files = {}
local hash_parts = {}
local previous
for index, record in ipairs(records) do
    assert(type(record) == "table" and safeRelative(record.path),
        "payload manifest contains an unsafe path")
    assert(type(record.executable) == "boolean", "payload mode is invalid")
    assert(previous == nil or previous < record.path,
        "payload manifest is not strictly sorted")
    previous = record.path
    local content = readFile(join(root, record.path))
    files[index] = {
        path = record.path,
        content = content,
        executable = record.executable,
    }
    hash_parts[#hash_parts + 1] = packU32(#record.path)
    hash_parts[#hash_parts + 1] = record.path
    hash_parts[#hash_parts + 1] = record.executable and "\1" or "\0"
    hash_parts[#hash_parts + 1] = packU32(math.floor(#content / 4294967296))
    hash_parts[#hash_parts + 1] = packU32(#content % 4294967296)
    hash_parts[#hash_parts + 1] = content
end

local output_path = normalize(arg[2] or join(root, ".luai/build/payload.inc"))
local hash_input = output_path .. ".sha256-input"
writeFile(hash_input, table.concat(hash_parts))
local payload_id = commandDigest(hash_input)
assert(os.remove(native(hash_input)), "cannot remove SHA-256 input")

local lines = {}
for index, file in ipairs(files) do
    lines[#lines + 1] = emitArray(index, file.content)
end
lines[#lines + 1] = "#define LUAI_PAYLOAD_ID " .. cString(payload_id)
lines[#lines + 1] = "#define LUAI_FILE_COUNT " .. tostring(#files)
lines[#lines + 1] = "static const struct luai_embedded_file luai_files[] = {"
for index, file in ipairs(files) do
    lines[#lines + 1] = string.format(
        "    { %s, luai_file_%d, %d, %d },",
        cString(file.path),
        index,
        #file.content,
        file.executable and 1 or 0
    )
end
lines[#lines + 1] = "};"
writeFile(output_path, table.concat(lines, "\n\n") .. "\n")
print(payload_id)
