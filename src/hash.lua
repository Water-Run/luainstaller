--[[
Deterministic content hashing for luainstaller.

Author:
    WaterRun
File:
    hash.lua
Date:
    2026-07-11
Updated:
    2026-08-16
]]

local compat = require("luainstaller.compat")

local M = {}

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

local NATIVE_COMPRESS_HEADER = [=[
return function(state_hash, block, offset)
    local MASK32 = 0xffffffff
    local constants = {
]=]
local NATIVE_COMPRESS_TAIL = [=[
    }
    local function mask32(value)
        return value & MASK32
    end
    local function rotateRight(value, count)
        value = mask32(value)
        return mask32((value >> count) | (value << (32 - count)))
    end
    local function wordAt(value, position)
        local a, b, c, d = value:byte(position, position + 3)
        return mask32((a << 24) | (b << 16) | (c << 8) | d)
    end

    offset = offset or 1
    local words = {}
    for index = 0, 15 do
        words[index] = wordAt(block, offset + index * 4)
    end
    for index = 16, 63 do
        local previous_15 = words[index - 15]
        local previous_2 = words[index - 2]
        local sigma0 = rotateRight(previous_15, 7)
            ~ rotateRight(previous_15, 18)
            ~ (previous_15 >> 3)
        local sigma1 = rotateRight(previous_2, 17)
            ~ rotateRight(previous_2, 19)
            ~ (previous_2 >> 10)
        words[index] = mask32(words[index - 16] + sigma0
            + words[index - 7] + sigma1)
    end

    local a, b, c, d = state_hash[1], state_hash[2], state_hash[3], state_hash[4]
    local e, f, g, h = state_hash[5], state_hash[6], state_hash[7], state_hash[8]
    for index = 0, 63 do
        local sum1 = rotateRight(e, 6) ~ rotateRight(e, 11) ~ rotateRight(e, 25)
        local choose = (e & f) ~ ((~e) & g)
        local temporary1 = mask32(h + sum1 + choose
            + constants[index + 1] + words[index])
        local sum0 = rotateRight(a, 2) ~ rotateRight(a, 13) ~ rotateRight(a, 22)
        local majority = (a & b) ~ (a & c) ~ (b & c)
        local temporary2 = mask32(sum0 + majority)
        h, g, f = g, f, e
        e = mask32(d + temporary1)
        d, c, b = c, b, a
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
]=]

local function mask32(value)
    return compat.uint32(value)
end

local sha256_backend = "portable-arithmetic"
local lua_version = compat.luaVersion()
local band, bxor, bnot = compat.band, compat.bxor, compat.bnot
local rshift, lshift, rrotate = compat.rshift, compat.lshift, compat.rrotate
if type(bit32) == "table" then
    sha256_backend = "bit32"
end

local function multiplyFNVPrime(value)
    -- 16777619 = 2^24 + 403.  Lua 5.1 represents numbers as doubles, so a
    -- direct 32-bit multiplication can lose low bits before the modulo.  Only
    -- the low byte contributes to the 2^24 term modulo 2^32, and both products
    -- below remain exactly representable on every supported Lua number model.
    return mask32(value * 403 + (value % 256) * 16777216)
end

local function rotateRight(value, count)
    value = mask32(value)
    return rrotate(value, count)
end

local function wordAt(content, position)
    local a, b, c, d = content:byte(position, position + 3)
    return mask32(
        lshift(a, 24) + lshift(b, 16) + lshift(c, 8) + d
    )
end

local function paddedTail(buffer, total_length)
    local zero_count = (56 - ((total_length + 1) % 64)) % 64
    -- Do not use the 32-bit compatibility shifts for the byte count: they
    -- truncate before shifting and therefore encode the wrong SHA-256 length
    -- for files of 4 GiB or more.
    local high = math.floor(total_length / 0x20000000) % 0x100000000
    local low = (total_length % 0x20000000) * 8
    return buffer
        .. "\128"
        .. string.rep("\0", zero_count)
        .. compat.packU32BE(high)
        .. compat.packU32BE(low)
end

local INITIAL_HASH = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
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

local compressBlock = portableCompressBlock
if lua_version.major == 5 and lua_version.minor and lua_version.minor >= 3 then
    local loader = loadstring or load
    local numbers = {}
    for index = 1, #SHA256_CONSTANTS do
        numbers[index] = tostring(SHA256_CONSTANTS[index])
    end
    local source = NATIVE_COMPRESS_HEADER
        .. table.concat(numbers, ", ")
        .. NATIVE_COMPRESS_TAIL
    local chunk, load_err = loader(source, "@luainstaller-native-compress")
    if not chunk then
        error("cannot load native SHA-256 compression: " .. tostring(load_err))
    end
    compressBlock = chunk()
    sha256_backend = "native-operators"
end

local function newSha256State()
    local copy = {}
    for index = 1, 8 do
        copy[index] = INITIAL_HASH[index]
    end
    return {
        hash = copy,
        length = 0,
        buffer = "",
    }
end

local function updateSha256(state, chunk)
    if type(chunk) ~= "string" then
        return nil, "sha256 update requires a string chunk"
    end
    state.length = state.length + #chunk
    local data = state.buffer .. chunk
    local full_bytes = #data - (#data % 64)
    local block_start = 1
    while block_start <= full_bytes do
        compressBlock(state.hash, data, block_start)
        block_start = block_start + 64
    end
    if full_bytes > 0 then
        state.buffer = data:sub(full_bytes + 1)
    else
        state.buffer = data
    end
    return true
end

local function finalizeSha256(state)
    local tail = paddedTail(state.buffer, state.length)
    local block_start = 1
    while block_start <= #tail do
        compressBlock(state.hash, tail, block_start)
        block_start = block_start + 64
    end
    local h = state.hash
    state.buffer = ""
    state.length = 0
    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    )
end

local function portableSha256(content)
    content = tostring(content or "")
    local state = newSha256State()
    assert(updateSha256(state, content))
    return finalizeSha256(state)
end

function M.sha256(content)
    return portableSha256(content)
end

--@description: Start an incremental SHA-256 computation
--@return: table - Hash state for updateSha256/finalizeSha256
function M.newSha256()
    return newSha256State()
end

--@description: Feed one chunk into an incremental SHA-256 computation
--@param state: table - State from newSha256
--@param chunk: string - Content bytes
--@return: boolean - True, or nil plus an error message
function M.updateSha256(state, chunk)
    if type(state) ~= "table" or type(state.hash) ~= "table" then
        return nil, "sha256 update requires a state from newSha256"
    end
    return updateSha256(state, chunk)
end

--@description: Finish an incremental SHA-256 computation
--@param state: table - State from newSha256
--@return: string - Hex digest
function M.finalizeSha256(state)
    if type(state) ~= "table" or type(state.hash) ~= "table" then
        return nil, "sha256 finalize requires a state from newSha256"
    end
    return finalizeSha256(state)
end

--@description: Hash a regular file in bounded memory
--@param path: string - File path
--@return: string|nil - Hex digest, or nil plus an error message
function M.sha256File(path)
    local opened, handle, open_err = pcall(io.open, path, "rb")
    if not opened or not handle then
        return nil, "cannot open file for hashing: "
            .. tostring(opened and open_err or handle)
    end
    local state = newSha256State()
    while true do
        local read_ok, chunk, read_err = pcall(handle.read, handle, 64 * 1024)
        if not read_ok or (chunk == nil and read_err ~= nil) then
            pcall(handle.close, handle)
            return nil, "cannot read file for hashing: "
                .. tostring(read_ok and read_err or chunk)
        end
        if chunk == nil then
            break
        end
        local updated, update_err = updateSha256(state, chunk)
        if not updated then
            pcall(handle.close, handle)
            return nil, update_err
        end
    end
    local close_ok, closed, close_err = pcall(handle.close, handle)
    if not close_ok or not closed then
        return nil, "cannot close file after hashing: "
            .. tostring(close_ok and close_err or closed)
    end
    return finalizeSha256(state)
end

function M.backend()
    return sha256_backend
end

function M.fnv1a32(content)
    content = tostring(content or "")
    local value = 2166136261
    for index = 1, #content do
        value = multiplyFNVPrime(compat.bxor(value, content:byte(index)))
    end
    return string.format("%08x", value)
end

return M
