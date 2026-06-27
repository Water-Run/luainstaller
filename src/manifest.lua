--[[
Bundle manifest construction for luainstaller.

Author:
    WaterRun
File:
    manifest.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local path = require("luainstaller.path")
local platform = require("luainstaller.platform")

local M = {}

local HASH_ALGORITHM = "fnv1a32"

local normalizePath = path.normalize
local absolutePath = path.absolute
local basename = path.basename
local dirname = path.dirname

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content or ""
end

local function fnv1a32(content)
    local hash = 2166136261
    for i = 1, #content do
        hash = hash ~ content:byte(i)
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function fileHash(path)
    local content = readFile(path)
    if not content then
        return nil
    end
    return fnv1a32(content)
end

local function relativePathUnder(path, base)
    path = normalizePath(path)
    base = normalizePath(base)
    local prefix = base == "/" and "/" or (base .. "/")
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return nil
end

local function safeExternalPath(path)
    path = normalizePath(path)
    path = path:gsub("^/", "")
    path = path:gsub(":", "")
    path = path:gsub("[^%w%._%-%/]", "_")
    if path == "" then
        return basename(path)
    end
    return normalizePath("external/" .. path)
end

local function luaInfo()
    local version = _VERSION or "Lua"
    local major, minor = version:match("Lua%s+(%d+)%.(%d+)")
    return {
        version = version,
        abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
    }
end

local function platformInfo()
    return platform.detectHost()
end

local function fileEntry(path, destination_root, entry_dir, preserve_relative)
    local source = absolutePath(path)
    local relative
    if preserve_relative then
        relative = entry_dir and relativePathUnder(source, entry_dir) or nil
        if not relative then
            relative = safeExternalPath(source)
        end
    else
        relative = basename(source)
    end
    return {
        source_path = source,
        destination_path = normalizePath(destination_root .. "/" .. relative),
        content_hash = fileHash(source),
    }
end

local function appendFileEntries(target, paths, destination_root, entry_dir, preserve_relative)
    for _, path in ipairs(paths or {}) do
        target[#target + 1] = fileEntry(path, destination_root, entry_dir, preserve_relative)
    end
end

local function duplicateDestinationError(path, first_source, second_source)
    return {
        ok = false,
        error = {
            type = "DuplicateModuleError",
            message = string.format("Duplicate manifest destination: %s", path),
            destination_path = path,
            first_source = first_source,
            second_source = second_source,
        },
    }
end

local function checkDuplicateDestinations(manifest)
    local seen = {}
    local groups = { manifest.modules.lua, manifest.modules.native, manifest.modules.external }
    for _, group in ipairs(groups) do
        for _, item in ipairs(group) do
            local existing = seen[item.destination_path]
            if existing and existing ~= item.source_path then
                return duplicateDestinationError(item.destination_path, existing, item.source_path)
            end
            seen[item.destination_path] = item.source_path
        end
    end
    return nil
end

function M.build(opts)
    opts = opts or {}
    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local entry_path = absolutePath(opts.entry)
    local entry_dir = dirname(entry_path)
    local manifest = {
        version = 1,
        hash_algorithm = HASH_ALGORITHM,
        entry = {
            source_path = entry_path,
            destination_path = normalizePath(".luai/lua/" .. basename(entry_path)),
            content_hash = fileHash(entry_path),
        },
        output = {
            mode = opts.mode or "onedir",
            path = opts.out,
        },
        lua = luaInfo(),
        platform = platformInfo(),
        launcher = {
            profile = opts.launcher_profile or "shared-lua",
        },
        modules = {
            lua = {},
            native = {},
            external = {},
        },
        manual = {
            include = opts.include or {},
            exclude = opts.exclude or {},
            depscan = opts.depscan ~= false,
        },
        trace = opts.trace or {},
        compatibility = {
            "same OS",
            "same architecture",
            "same ABI",
            "same Lua ABI",
        },
    }

    appendFileEntries(manifest.modules.lua, dependencies.scripts, ".luai/lua", entry_dir, true)
    appendFileEntries(manifest.modules.native, dependencies.libraries, ".luai/native", entry_dir, false)

    local duplicate = checkDuplicateDestinations(manifest)
    if duplicate then
        return duplicate
    end

    return {
        ok = true,
        manifest = manifest,
    }
end

return M
