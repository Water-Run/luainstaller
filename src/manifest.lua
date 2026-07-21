--[[
Bundle manifest construction for luainstaller.

Author:
    WaterRun
File:
    manifest.lua
Date:
    2026-06-16
Updated:
    2026-07-18
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

local function logicalSourceId(source, entry_dir, content_hash)
    local relative = path.relativeWithin(source, entry_dir)
    if relative then return normalizePath(relative) end
    local name = basename(source):gsub("[^%w._-]", "_")
    if name == "" or name == "." or name == ".." then name = "source" end
    return normalizePath("external/" .. content_hash .. "/" .. name)
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

local function discoveryInfo(discovery)
    if type(discovery) ~= "table" then return nil end
    local info = {
        mode = discovery.mode,
    }
    local interpreter = discovery.interpreter
    if type(interpreter) == "table" then
        info.interpreter = {
            command = type(interpreter.path) == "string"
                and basename(interpreter.path) or nil,
            abi = interpreter.abi,
            version = interpreter.version,
        }
    end
    return info
end

local function fileEntry(path, destination_root, entry_dir, preserve_relative, source_hashes)
    local source = absolutePath(path)
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
    local source_id = logicalSourceId(source, entry_dir, content_hash)
    local relative = preserve_relative and source_id or basename(source)
    return {
        source_path = source,
        source_id = source_id,
        destination_path = normalizePath(destination_root .. "/" .. relative),
        content_hash = content_hash,
    }
end

local function copyValue(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, child in pairs(value) do copied[key] = copyValue(child) end
    return copied
end

local function distributionFileEntry(entry)
    return {
        source_id = entry.source_id,
        destination_path = entry.destination_path,
        content_hash = entry.content_hash,
    }
end

local function sourceIdMap(manifest)
    local ids = {}
    local groups = {
        { manifest.entry },
        manifest.modules.lua or {},
        manifest.modules.native or {},
        manifest.modules.external or {},
    }
    for _, group in ipairs(groups) do
        for _, entry in ipairs(group) do
            if type(entry.source_path) == "string" and type(entry.source_id) == "string" then
                ids[normalizePath(absolutePath(entry.source_path))] = entry.source_id
            end
        end
    end
    return ids
end

local function distributionTrace(manifest)
    local ids = sourceIdMap(manifest)
    local trace = {}
    for _, item in ipairs(manifest.trace or {}) do
        local record = {
            requested = item.requested,
            classification = item.classification,
            selected_type = item.selected_type,
            reason = item.reason,
            optional = item.optional and true or nil,
            source_line = item.source_line,
        }
        if type(item.selected_path) == "string" then
            record.selected_source_id = ids[normalizePath(absolutePath(item.selected_path))]
        end
        if type(item.requiring_file) == "string" then
            record.requiring_source_id = ids[normalizePath(absolutePath(item.requiring_file))]
        end
        trace[#trace + 1] = record
    end
    return trace
end

local function distributionEntries(entries)
    local result = {}
    for _, entry in ipairs(entries or {}) do
        result[#result + 1] = distributionFileEntry(entry)
    end
    return result
end

--@description: Return the path-clean manifest that is written into artifacts.
function M.distribution(manifest)
    local runtime = manifest.launcher and manifest.launcher.lua_runtime or nil
    local launcher = {
        profile = manifest.launcher and manifest.launcher.profile or nil,
    }
    if runtime then
        launcher.lua_runtime = {
            source_id = runtime.source_id or ("runtime/" .. basename(
                runtime.destination_path or runtime.source_path or "lua-runtime"
            )),
            destination_path = runtime.destination_path,
            link_mode = runtime.link_mode,
        }
    end
    return {
        version = manifest.version,
        hash_algorithm = manifest.hash_algorithm,
        entry = distributionFileEntry(manifest.entry),
        output = { mode = manifest.output and manifest.output.mode or "onedir" },
        lua = copyValue(manifest.lua),
        platform = copyValue(manifest.platform),
        launcher = launcher,
        modules = {
            lua = distributionEntries(manifest.modules and manifest.modules.lua),
            native = distributionEntries(manifest.modules and manifest.modules.native),
            external = distributionEntries(manifest.modules and manifest.modules.external),
        },
        manual = {
            depscan = manifest.manual and manifest.manual.depscan ~= false,
            include_count = #(manifest.manual and manifest.manual.include or {}),
            exclude_count = #(manifest.manual and manifest.manual.exclude or {}),
        },
        discovery = copyValue(manifest.discovery),
        trace = distributionTrace(manifest),
        compatibility = copyValue(manifest.compatibility),
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
    local profile, profile_err = platform.profile({
        host = host,
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    if not profile then return profile_err end
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
        discovery = discoveryInfo(opts.discovery),
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
