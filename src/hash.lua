--[[
Deterministic content hashing for luainstaller.

Author:
    WaterRun
File:
    hash.lua
Date:
    2026-07-11
Updated:
    2026-07-18
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

local NATIVE_SHA256_SOURCE = [=[
return function(content)
    local MASK32 = 0xffffffff
    local constants = {
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

    content = tostring(content or "")
    local byte_length = #content
    local high = (byte_length >> 29) & MASK32
    local low = (byte_length << 3) & MASK32
    local zero_count = (56 - ((byte_length + 1) % 64)) % 64
    local message = content .. "\128" .. string.rep("\0", zero_count)
        .. string.pack(">I4I4", high, low)
    local h0, h1 = 0x6a09e667, 0xbb67ae85
    local h2, h3 = 0x3c6ef372, 0xa54ff53a
    local h4, h5 = 0x510e527f, 0x9b05688c
    local h6, h7 = 0x1f83d9ab, 0x5be0cd19

    for block = 1, #message, 64 do
        local words = {}
        for index = 0, 15 do
            words[index] = wordAt(message, block + index * 4)
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

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
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

        h0, h1 = mask32(h0 + a), mask32(h1 + b)
        h2, h3 = mask32(h2 + c), mask32(h3 + d)
        h4, h5 = mask32(h4 + e), mask32(h5 + f)
        h6, h7 = mask32(h6 + g), mask32(h7 + h)
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7)
end
]=]

local function mask32(value)
    return compat.uint32(value)
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
    return compat.rrotate(value, count)
end

local function wordAt(content, position)
    local a, b, c, d = content:byte(position, position + 3)
    return compat.bor(
        compat.lshift(a, 24),
        compat.lshift(b, 16),
        compat.lshift(c, 8),
        d
    )
end

local function paddedMessage(content)
    local byte_length = #content
    local high = compat.rshift(byte_length, 29)
    local low = compat.lshift(byte_length, 3)
    local zero_count = (56 - ((byte_length + 1) % 64)) % 64
    return content
        .. "\128"
        .. string.rep("\0", zero_count)
        .. compat.packU32BE(high)
        .. compat.packU32BE(low)
end

local function portableSha256(content)
    content = tostring(content or "")
    local message = paddedMessage(content)
    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    for block = 1, #message, 64 do
        local words = {}
        for index = 0, 15 do
            words[index] = wordAt(message, block + index * 4)
        end
        for index = 16, 63 do
            local previous_15 = words[index - 15]
            local previous_2 = words[index - 2]
            local sigma0 = compat.bxor(
                rotateRight(previous_15, 7),
                rotateRight(previous_15, 18),
                compat.rshift(previous_15, 3)
            )
            local sigma1 = compat.bxor(
                rotateRight(previous_2, 17),
                rotateRight(previous_2, 19),
                compat.rshift(previous_2, 10)
            )
            words[index] = mask32(
                words[index - 16] + sigma0 + words[index - 7] + sigma1
            )
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 0, 63 do
            local sum1 = compat.bxor(rotateRight(e, 6), rotateRight(e, 11), rotateRight(e, 25))
            local choose = compat.bxor(compat.band(e, f), compat.band(compat.bnot(e), g))
            local temporary1 = mask32(
                h + sum1 + choose + SHA256_CONSTANTS[index + 1] + words[index]
            )
            local sum0 = compat.bxor(rotateRight(a, 2), rotateRight(a, 13), rotateRight(a, 22))
            local majority = compat.bxor(compat.band(a, b), compat.band(a, c), compat.band(b, c))
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

        h0 = mask32(h0 + a)
        h1 = mask32(h1 + b)
        h2 = mask32(h2 + c)
        h3 = mask32(h3 + d)
        h4 = mask32(h4 + e)
        h5 = mask32(h5 + f)
        h6 = mask32(h6 + g)
        h7 = mask32(h7 + h)
    end

    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7
    )
end

local sha256_backend = "portable-arithmetic"
local sha256_implementation = portableSha256
local lua_version = compat.luaVersion()
if lua_version.major == 5 and lua_version.minor and lua_version.minor >= 3 then
    local loader = loadstring or load
    local native_chunk, native_err = loader(NATIVE_SHA256_SOURCE, "@luainstaller-native-sha256")
    if not native_chunk then
        error("cannot load native SHA-256 backend: " .. tostring(native_err))
    end
    sha256_implementation = native_chunk()
    sha256_backend = "native-operators"
elseif type(bit32) == "table" then
    sha256_backend = "bit32"
end

function M.sha256(content)
    return sha256_implementation(content)
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
