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

local M = {}

local HASH_ALGORITHM = "fnv1a32"

local function normalizePath(path)
    path = tostring(path or ""):gsub("\\", "/")
    local prefix = ""
    if path:match("^//") then
        prefix = "//"
        path = path:sub(3)
    elseif path:match("^%a:/") then
        prefix = path:sub(1, 3)
        path = path:sub(4)
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        path = path:sub(2)
    end

    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = ".."
            end
        elseif segment ~= "." and segment ~= "" then
            parts[#parts + 1] = segment
        end
    end

    local result = prefix .. table.concat(parts, "/")
    if result == "" then
        return "."
    end
    return result
end

local function isAbsolutePath(path)
    return path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil
end

local function commandLine(command)
    if type(io.popen) ~= "function" then
        return nil
    end
    local ok, pipe = pcall(io.popen, command)
    if not ok or not pipe then
        return nil
    end
    local value = pipe:read("*l")
    pipe:close()
    if value and value ~= "" then
        return value
    end
    return nil
end

local function currentDirectory()
    local dir = commandLine(package.config:sub(1, 1) == "\\" and "cd" or "pwd")
    if dir then
        return normalizePath(dir)
    end
    return "."
end

local function absolutePath(path)
    path = normalizePath(path)
    if isAbsolutePath(path) then
        return path
    end
    return normalizePath(currentDirectory() .. "/" .. path)
end

local function basename(path)
    path = normalizePath(path)
    return path:match("[^/]+$") or path
end

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

local function luaInfo()
    local version = _VERSION or "Lua"
    local major, minor = version:match("Lua%s+(%d+)%.(%d+)")
    return {
        version = version,
        abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
    }
end

local function platformInfo()
    local sep = package.config:sub(1, 1)
    local os_name = sep == "\\" and "windows" or "unknown"
    local arch = "unknown"

    if sep ~= "\\" then
        local os_value = commandLine("uname -s 2>/dev/null")
        if os_value then
            os_name = os_value:lower()
        end

        local arch_value = commandLine("uname -m 2>/dev/null")
        if arch_value then
            arch = arch_value
        end
    end

    return {
        os = os_name,
        arch = arch,
    }
end

local function fileEntry(path, destination_root)
    local source = absolutePath(path)
    return {
        source_path = source,
        destination_path = normalizePath(destination_root .. "/" .. basename(source)),
        content_hash = fileHash(source),
    }
end

local function appendFileEntries(target, paths, destination_root)
    for _, path in ipairs(paths or {}) do
        target[#target + 1] = fileEntry(path, destination_root)
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

    appendFileEntries(manifest.modules.lua, dependencies.scripts, ".luai/lua")
    appendFileEntries(manifest.modules.native, dependencies.libraries, ".luai/native")

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
