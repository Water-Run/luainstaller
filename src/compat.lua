--[[
Compatibility diagnostics for luainstaller bundle planning.

Author:
    WaterRun
File:
    compat.lua
Date:
    2026-06-22
Updated:
    2026-07-11
]]

local platform = require("luainstaller.platform")

local M = {}
local UINT32 = 4294967296
local UINT32_MAX = UINT32 - 1

local function uint32(value)
    value = tonumber(value) or 0
    value = value % UINT32
    if value < 0 then
        value = value + UINT32
    end
    return value
end

M.uint32 = uint32

local function arithmeticBitOp(left, right, operation)
    left = uint32(left)
    right = uint32(right)
    local result = 0
    local bit_value = 1
    for _ = 1, 32 do
        local left_bit = left % 2
        local right_bit = right % 2
        if operation(left_bit, right_bit) then
            result = result + bit_value
        end
        left = (left - left_bit) / 2
        right = (right - right_bit) / 2
        bit_value = bit_value * 2
    end
    return result
end

local native_bits
if _VERSION ~= "Lua 5.1" and _VERSION ~= "Lua 5.2" then
    local loader = loadstring or load
    local chunk = loader([[
return {
    band = function(a, b) return (a & b) & 0xffffffff end,
    bor = function(a, b) return (a | b) & 0xffffffff end,
    bxor = function(a, b) return (a ~ b) & 0xffffffff end,
    bnot = function(a) return (~a) & 0xffffffff end,
    lshift = function(a, n) return (a << n) & 0xffffffff end,
    rshift = function(a, n) return (a & 0xffffffff) >> n end,
}
]], "@luainstaller-native-bits")
    if chunk then
        native_bits = chunk()
    end
elseif type(bit32) == "table" then
    native_bits = bit32
end

local function foldBitOperation(name, fallback, first, second, ...)
    local operation = native_bits and native_bits[name]
    local result
    if operation then
        result = operation(first, second)
    else
        result = arithmeticBitOp(first, second, fallback)
    end
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if operation then
            result = operation(result, value)
        else
            result = arithmeticBitOp(result, value, fallback)
        end
    end
    return uint32(result)
end

function M.band(first, second, ...)
    return foldBitOperation("band", function(a, b) return a == 1 and b == 1 end,
        first, second, ...)
end

function M.bor(first, second, ...)
    return foldBitOperation("bor", function(a, b) return a == 1 or b == 1 end,
        first, second, ...)
end

function M.bxor(first, second, ...)
    return foldBitOperation("bxor", function(a, b) return a ~= b end,
        first, second, ...)
end

function M.bnot(value)
    if native_bits and native_bits.bnot then
        return uint32(native_bits.bnot(value))
    end
    return UINT32_MAX - uint32(value)
end

function M.lshift(value, count)
    count = tonumber(count) or 0
    if count < 0 then return M.rshift(value, -count) end
    if count >= 32 then return 0 end
    if native_bits and native_bits.lshift then
        return uint32(native_bits.lshift(value, count))
    end
    return uint32(uint32(value) * 2 ^ count)
end

function M.rshift(value, count)
    count = tonumber(count) or 0
    if count < 0 then return M.lshift(value, -count) end
    if count >= 32 then return 0 end
    if native_bits and native_bits.rshift then
        return uint32(native_bits.rshift(value, count))
    end
    return math.floor(uint32(value) / 2 ^ count)
end

function M.rrotate(value, count)
    count = (tonumber(count) or 0) % 32
    if count == 0 then return uint32(value) end
    return M.bor(M.rshift(value, count), M.lshift(value, 32 - count))
end

function M.packU32BE(value)
    value = uint32(value)
    return string.char(
        math.floor(value / 0x1000000) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x100) % 0x100,
        value % 0x100
    )
end

function M.loadText(source, chunk_name, environment)
    if type(source) ~= "string" then
        return nil, "source must be a string"
    end
    if source:byte(1) == 27 then
        return nil, "binary chunks are not accepted"
    end
    if _VERSION == "Lua 5.1" then
        local loader, err = loadstring(source, chunk_name)
        if loader and environment then
            setfenv(loader, environment)
        end
        return loader, err
    end
    return load(source, chunk_name, "t", environment)
end

M.unpack = table.unpack or unpack

function M.searchpath(name, search_path, separator, replacement)
    if package.searchpath then
        return package.searchpath(name, search_path, separator, replacement)
    end
    separator = separator or "."
    replacement = replacement or package.config:sub(1, 1)
    local escaped_separator = separator:gsub("([^%w])", "%%%1")
    local module_path = tostring(name):gsub(escaped_separator, replacement)
    local errors = {}
    for template in tostring(search_path or ""):gmatch("[^;]+") do
        local candidate = template:gsub("%?", module_path)
        local handle = io.open(candidate, "rb")
        if handle then
            handle:close()
            return candidate
        end
        errors[#errors + 1] = "\n\tno file '" .. candidate .. "'"
    end
    return nil, table.concat(errors)
end

function M.luaVersion()
    local version = _VERSION or "Lua"
    local major, minor = version:match("Lua%s+(%d+)%.(%d+)")
    major = tonumber(major)
    minor = tonumber(minor)
    return {
        version = version,
        abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
        major = major,
        minor = minor,
        num = major and minor and (major * 100 + minor) or nil,
    }
end

local function modeName(opts)
    return opts and opts.mode or "onedir"
end

local function countLibraries(dependencies)
    return #(dependencies and dependencies.libraries or {})
end

function M.diagnose(opts)
    opts = opts or {}
    local host = platform.detectHost()
    local profile = platform.profile({
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    local lua = M.luaVersion()
    local library_count = countLibraries(opts.dependencies)
    local notes = {
        "does not claim universal cross-platform output",
        "requires same OS, same architecture, same ABI, and same Lua ABI",
        "runtime require discovery only covers build-time executed code paths",
    }
    local warnings = {}

    if library_count > 0 then
        warnings[#warnings + 1] = "native Lua C modules may require external shared libraries that are not automatically closed over"
    end

    if profile.target_os ~= host.os then
        warnings[#warnings + 1] = "target profile differs from the build host; verify with the target runtime"
    end
    if profile.target_arch ~= platform.normalizeArch(host.arch) then
        warnings[#warnings + 1] = "target architecture differs from the build host; verify every native dependency"
    end

    if profile.target_os == "windows" then
        notes[#notes + 1] = "Windows bundles require a compatible Lua DLL and compiler-runtime family"
    elseif profile.target_os == "macos" then
        notes[#notes + 1] = "macOS bundles require a matching static Lua prefix at build time"
    elseif profile.target_os == "linux" then
        notes[#notes + 1] = "Linux bundles use the copied shared Lua runtime and same-ABI native modules"
    end

    return {
        summary = "same OS, same architecture, same ABI, same Lua ABI",
        host = host,
        target = {
            os = profile.target_os,
            arch = profile.target_arch,
            executable_suffix = profile.executable_suffix,
            launcher_profile = profile.launcher_profile,
        },
        lua = lua,
        mode = modeName(opts),
        native_library_count = library_count,
        notes = notes,
        warnings = warnings,
    }
end

return M
