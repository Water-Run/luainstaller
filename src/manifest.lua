--[[
Bundle manifest construction for luainstaller.

Author:
    WaterRun
File:
    manifest.lua
Date:
    2026-06-16
Updated:
    2026-07-11
]]

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local compat = require("luainstaller.compat")

local M = {}

local HASH_ALGORITHM = "sha256"

local normalizePath = path.normalize
local absolutePath = path.absolute
local basename = path.basename
local dirname = path.dirname

local function readFile(path)
    return fs.readFile(path)
end

-- Kept as a compatibility export for callers that still inspect legacy hashes.
M.fnv1a32 = hash.fnv1a32

local function fileHash(path)
    local content, read_err = readFile(path)
    if not content then
        return nil, read_err
    end
    return hash.sha256(content)
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
    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment ~= "" and segment ~= "." and segment ~= ".." then
            parts[#parts + 1] = segment
        end
    end
    if #parts == 0 then
        return normalizePath("external/" .. basename(path))
    end
    return normalizePath("external/" .. table.concat(parts, "/"))
end

local function luaInfo(configured)
    local current = configured or compat.luaVersion()
    local major = tonumber(current.major)
    local minor = tonumber(current.minor)
    local number = tonumber(current.num) or (major and minor and (major * 100 + minor))
    return {
        version = current.version or (major and minor
            and string.format("Lua %d.%d", major, minor) or "Lua"),
        major = major,
        minor = minor,
        num = number,
        abi = current.abi or (major and minor
            and ("lua" .. major .. "." .. minor) or "unknown"),
    }
end

local function platformInfo(host, profile)
    return {
        host = {
            os = host.os,
            arch = platform.normalizeArch(host.arch),
        },
        target = {
            os = profile.target_os,
            arch = profile.target_arch,
        },
    }
end

local function launcherProfile(profile)
    return profile.launcher_profile
end

local function fileEntry(path, destination_root, entry_dir, preserve_relative, source_hashes)
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
    local content_hash, hash_err = fileHash(source)
    if not content_hash then
        return nil, {
            ok = false,
            error = {
                type = "FilesystemError",
                message = "Cannot snapshot source file: " .. tostring(source),
                source_path = source,
                cause = hash_err,
            },
        }
    end
    if source_hashes then
        local expected_hash = source_hashes[source]
            or source_hashes[normalizePath(path)]
            or source_hashes[path]
        if expected_hash == nil then
            return nil, {
                ok = false,
                error = {
                    type = "InvalidManifestError",
                    message = "Discovery snapshot is missing source file: " .. tostring(source),
                    source_path = source,
                },
            }
        end
        if expected_hash ~= content_hash then
            return nil, {
                ok = false,
                error = {
                    type = "SourceChangedError",
                    message = "Source changed after dependency discovery: " .. tostring(source),
                    source_path = source,
                    expected_hash = expected_hash,
                    actual_hash = content_hash,
                    hash_algorithm = HASH_ALGORITHM,
                },
            }
        end
    end
    return {
        source_path = source,
        destination_path = normalizePath(destination_root .. "/" .. relative),
        content_hash = content_hash,
    }
end

local function appendFileEntries(
    target,
    paths,
    destination_root,
    entry_dir,
    preserve_relative,
    source_hashes
)
    for _, path in ipairs(paths or {}) do
        local entry, entry_err = fileEntry(
            path,
            destination_root,
            entry_dir,
            preserve_relative,
            source_hashes
        )
        if not entry then return entry_err end
        target[#target + 1] = entry
    end
    return nil
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

local function checkDuplicateDestinations(manifest, target_os)
    local seen = {}
    local groups = {
        { manifest.entry },
        manifest.modules.lua,
        manifest.modules.native,
        manifest.modules.external,
    }
    for _, group in ipairs(groups) do
        for _, item in ipairs(group) do
            local valid, reason = path.validateTargetRelative(item.destination_path, target_os)
            if not valid then
                return {
                    ok = false,
                    error = {
                        type = "InvalidOptionsError",
                        message = string.format(
                            "Invalid %s target path: %s (%s)",
                            tostring(target_os),
                            tostring(item.destination_path),
                            tostring(reason)
                        ),
                        destination_path = item.destination_path,
                        target_os = target_os,
                        reason = reason,
                    },
                }
            end
            local key = path.targetKey(item.destination_path, target_os)
            local existing = seen[key]
            if existing and existing.source_path ~= item.source_path then
                return duplicateDestinationError(
                    item.destination_path,
                    existing.source_path,
                    item.source_path
                )
            end
            seen[key] = item
        end
    end
    return nil
end

function M.build(opts)
    opts = opts or {}
    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local entry_path = absolutePath(opts.entry)
    local entry_dir = dirname(entry_path)
    local host = platform.detectHost()
    local profile = platform.profile({
        host = host,
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    local entry_record, entry_err = fileEntry(
        entry_path,
        ".luai/lua",
        entry_dir,
        false,
        opts.source_hashes
    )
    if not entry_record then return entry_err end
    local manifest = {
        version = 2,
        hash_algorithm = HASH_ALGORITHM,
        entry = entry_record,
        output = {
            mode = opts.mode or "onedir",
            path = opts.out,
        },
        lua = luaInfo(opts.lua_version),
        platform = platformInfo(host, profile),
        launcher = {
            profile = launcherProfile(profile),
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
        -- Declared packaging requirement (not a host/target snapshot).
        -- Structured diagnostics live on trace/compatibility API results.
        compatibility = {
            "same OS",
            "same architecture",
            "same ABI",
            "same Lua ABI",
        },
    }

    local append_err = appendFileEntries(
        manifest.modules.lua,
        dependencies.scripts,
        ".luai/lua",
        entry_dir,
        true,
        opts.source_hashes
    ) or appendFileEntries(
        manifest.modules.native,
        dependencies.libraries,
        ".luai/native",
        entry_dir,
        false,
        opts.source_hashes
    )
    if append_err then return append_err end

    local duplicate = checkDuplicateDestinations(manifest, profile.target_os)
    if duplicate then
        return duplicate
    end

    return {
        ok = true,
        manifest = manifest,
    }
end

return M
