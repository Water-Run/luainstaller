--[[
Same-platform and profiled onedir bundler for luainstaller.

Author:
    WaterRun
File:
    bundler.lua
Date:
    2026-06-21
Updated:
    2026-07-11
]]

local launcher = require("luainstaller.launcher")
local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local hash_mod = require("luainstaller.hash")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local process = require("luainstaller.process")
local result = require("luainstaller.result")
local toolchain = require("luainstaller.toolchain")

local M = {}

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"

local normalizePath = path.normalize
local absolutePath = path.absolute
local currentDirectory = path.currentDirectory
local dirname = path.dirname
local basename = path.basename
local stem = path.stem
local isWithin = path.isWithin
local isSafeRelative = path.isSafeRelative
local validateTargetRelative = path.validateTargetRelative
local targetKey = path.targetKey
local commandOutput = process.output
local shellQuote = process.shellQuote
local makeError = result.error
local GENERATED_MARKER = "luainstaller-generated-output-v2"
local GENERATED_MARKER_RELATIVE = ".luai/generated-output.txt"
local writeFile
local validateOutputDirectory

local function fromThrownError(err)
    return result.fromThrown(err, "LauncherGenerationError")
end

local function ensureDirectory(path)
    local ok, output = commandOutput("mkdir -p " .. shellQuote(path))
    if not ok then
        return makeError("FilesystemError", "Cannot create directory: " .. tostring(path), {
            output = output,
            path = path,
        })
    end
    return nil
end

local function removeTree(path)
    local ok, output = commandOutput("rm -rf " .. shellQuote(path))
    if not ok then
        return makeError("FilesystemError", "Cannot remove directory: " .. tostring(path), {
            output = output,
            path = path,
        })
    end
    return nil
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function contentHash(content, algorithm)
    if algorithm == "fnv1a32" then
        return hash_mod.fnv1a32(content)
    end
    if algorithm == "sha256" then
        return hash_mod.sha256(content)
    end
    return nil, makeError("InvalidManifestError", "Unsupported manifest hash algorithm: " .. tostring(algorithm), {
        hash_algorithm = algorithm,
    })
end

local function sourceChangedError(source_path, expected_hash, actual_hash, algorithm, details)
    details = details or {}
    details.source_path = normalizePath(source_path)
    details.expected_hash = expected_hash
    details.actual_hash = actual_hash
    details.hash_algorithm = algorithm
    return makeError("SourceChangedError", "Source changed during build: " .. tostring(source_path), details)
end

local function manifestSourceEntries(manifest)
    if type(manifest) ~= "table" or type(manifest.entry) ~= "table"
        or type(manifest.modules) ~= "table" then
        return nil, makeError("InvalidManifestError", "Manifest is missing source metadata")
    end
    local entries = {}
    entries[#entries + 1] = manifest.entry
    for _, group_name in ipairs({ "lua", "native", "external" }) do
        local group = manifest.modules[group_name]
        if group ~= nil and type(group) ~= "table" then
            return nil, makeError("InvalidManifestError", "Manifest module group must be a table", {
                module_group = group_name,
            })
        end
        for _, entry in ipairs(group or {}) do
            if type(entry) ~= "table" then
                return nil, makeError("InvalidManifestError", "Manifest source entry must be a table", {
                    module_group = group_name,
                })
            end
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function manifestSourceHashes(manifest)
    local algorithm = manifest and manifest.hash_algorithm
    local _, algorithm_err = contentHash("", algorithm)
    if algorithm_err then return nil, algorithm_err end
    local hashes = {}
    local entries, entries_err = manifestSourceEntries(manifest)
    if not entries then return nil, entries_err end
    for _, entry in ipairs(entries) do
        if type(entry.source_path) ~= "string" or entry.source_path == ""
            or type(entry.content_hash) ~= "string" or entry.content_hash == "" then
            return nil, makeError("InvalidManifestError", "Manifest source entry is missing a path or hash", {
                source_path = entry.source_path,
            })
        end
        local source_path = normalizePath(entry.source_path)
        local previous = hashes[source_path]
        if previous and previous ~= entry.content_hash then
            return nil, makeError("InvalidManifestError", "Manifest has conflicting hashes for one source", {
                source_path = source_path,
                first_hash = previous,
                second_hash = entry.content_hash,
            })
        end
        hashes[source_path] = entry.content_hash
    end
    return hashes
end

local function verifyManifestSources(manifest)
    local algorithm = manifest and manifest.hash_algorithm
    local entries, entries_err = manifestSourceEntries(manifest)
    if not entries then return entries_err end
    for _, entry in ipairs(entries) do
        local source_path = entry.source_path
        local content, read_err = fs.readRegularFile(source_path)
        if content == nil then
            return sourceChangedError(source_path, entry.content_hash, nil, algorithm, {
                cause = read_err,
            })
        end
        local actual_hash, hash_err = contentHash(content, algorithm)
        if hash_err then return hash_err end
        if actual_hash ~= entry.content_hash then
            return sourceChangedError(source_path, entry.content_hash, actual_hash, algorithm)
        end
    end
    return nil
end

local function pathExists(path)
    local ok = commandOutput("test -e " .. shellQuote(path))
    return ok == true
end

local function directoryExists(path)
    local ok = commandOutput("test -d " .. shellQuote(path))
    return ok == true
end

local function isSymlink(path)
    local ok = commandOutput("test -L " .. shellQuote(path))
    return ok == true
end

local function invalidOutputInventory(path, message, details)
    details = details or {}
    details.path = details.path or path
    return makeError("InvalidOutputError", message, details)
end

local function validInventoryPath(value)
    return type(value) == "string"
        and value ~= ""
        and value == normalizePath(value)
        and isSafeRelative(value)
        and not value:find("[\0\t\r\n]")
end

local function listTree(root)
    root = normalizePath(root)
    local ok, raw = commandOutput("find " .. shellQuote(root) .. " -print0")
    if not ok then
        return nil, invalidOutputInventory(root, "Cannot inspect output tree safely", {
            output = raw,
        })
    end
    local root_terminator = raw:find("\0", 1, true)
    if not root_terminator
        or normalizePath(raw:sub(1, root_terminator - 1)) ~= root then
        return nil, invalidOutputInventory(root, "Output tree listing omitted its root")
    end
    local prefix = root == "/" and "/" or (root .. "/")
    local entries = {}
    local seen = {}
    local position = root_terminator + 1
    while position <= #raw do
        local terminator = raw:find("\0", position, true)
        if not terminator then
            return nil, invalidOutputInventory(root, "Output tree listing is incomplete")
        end
        local listed_path = raw:sub(position, terminator - 1)
        local absolute = normalizePath(listed_path)
        position = terminator + 1
        if listed_path ~= absolute then
            return nil, invalidOutputInventory(root, "Output tree contains a path with ambiguous spelling", {
                unexpected_path = listed_path,
            })
        end
        if absolute:sub(1, #prefix) ~= prefix then
            return nil, invalidOutputInventory(root, "Output tree entry escapes its root", {
                unexpected_path = absolute,
            })
        end
        local relative = absolute:sub(#prefix + 1)
        if not validInventoryPath(relative) then
            return nil, invalidOutputInventory(root, "Output tree contains an unsafe path", {
                unexpected_path = absolute,
            })
        end
        if seen[relative] then
            return nil, invalidOutputInventory(root, "Output tree contains duplicate normalized paths", {
                unexpected_path = absolute,
            })
        end
        seen[relative] = true

        local item = { path = relative }
        if isSymlink(absolute) then
            return nil, invalidOutputInventory(root, "Output tree contains a symbolic link", {
                unexpected_path = absolute,
            })
        elseif directoryExists(absolute) then
            item.kind = "dir"
        elseif fs.isRegularFile(absolute) then
            local content, read_err = fs.readRegularFile(absolute)
            if content == nil then
                return nil, invalidOutputInventory(root, "Cannot read generated output file", {
                    unexpected_path = absolute,
                    cause = read_err,
                })
            end
            item.kind = "file"
            item.hash = hash_mod.sha256(content)
        else
            return nil, invalidOutputInventory(root, "Output tree contains an unsupported file type", {
                unexpected_path = absolute,
            })
        end
        entries[#entries + 1] = item
    end
    table.sort(entries, function(left, right)
        return left.path < right.path
    end)
    return entries
end

local function readGeneratedMarker(path)
    local marker_path = normalizePath(path .. "/" .. GENERATED_MARKER_RELATIVE)
    local content, read_err = fs.readFile(marker_path)
    if content == nil then
        return nil, invalidOutputInventory(path, "Generated output marker is missing or unreadable", {
            unexpected_path = marker_path,
            cause = read_err,
        })
    end
    if content:sub(-1) ~= "\n" then
        return nil, invalidOutputInventory(path, "Generated output marker is incomplete", {
            unexpected_path = marker_path,
        })
    end

    local lines = {}
    for line in content:gmatch("([^\n]*)\n") do
        if line == "" then
            return nil, invalidOutputInventory(path, "Generated output marker contains an empty record", {
                unexpected_path = marker_path,
            })
        end
        lines[#lines + 1] = line
    end
    if lines[1] == "luainstaller-generated-output-v1" then
        return nil, invalidOutputInventory(path, "Legacy v1 output requires explicit migration and will not be overwritten", {
            unexpected_path = marker_path,
            legacy_version = 1,
            migration_required = true,
        })
    end
    if lines[1] ~= GENERATED_MARKER then
        return nil, invalidOutputInventory(path, "Generated output marker has an unsupported version", {
            unexpected_path = marker_path,
        })
    end

    local marker = { entries = {} }
    for index = 2, #lines do
        local line = lines[index]
        if line:sub(1, #"output_dir=") == "output_dir=" then
            if marker.output_dir ~= nil then
                return nil, invalidOutputInventory(path, "Generated output marker repeats output_dir", {
                    unexpected_path = marker_path,
                })
            end
            marker.output_dir = normalizePath(line:sub(#"output_dir=" + 1))
        else
            local kind, relative, digest = line:match("^(dir)\t([^\t]+)$")
            if not kind then
                kind, relative, digest = line:match("^(file)\t([^\t]+)\t([0-9a-f]+)$")
            end
            if not kind or not validInventoryPath(relative)
                or relative == GENERATED_MARKER_RELATIVE
                or (kind == "file" and (type(digest) ~= "string" or #digest ~= 64))
                or marker.entries[relative] ~= nil then
                return nil, invalidOutputInventory(path, "Generated output marker contains an invalid inventory record", {
                    unexpected_path = marker_path,
                    record = line,
                })
            end
            marker.entries[relative] = {
                kind = kind,
                path = relative,
                hash = digest,
            }
        end
    end
    if marker.output_dir == nil or marker.output_dir == "" then
        return nil, invalidOutputInventory(path, "Generated output marker is missing output_dir", {
            unexpected_path = marker_path,
        })
    end
    return marker
end

local function generatedMarkerMatches(path, allowed, declared_output_dir)
    local marker, marker_err = readGeneratedMarker(path)
    if not marker then return false, marker_err end
    local expected_output_dir = normalizePath(declared_output_dir or path)
    if marker.output_dir ~= expected_output_dir then
        return false, invalidOutputInventory(path, "Generated output marker belongs to another directory", {
            unexpected_path = normalizePath(path .. "/" .. GENERATED_MARKER_RELATIVE),
            declared_output_dir = marker.output_dir,
            expected_output_dir = expected_output_dir,
        })
    end

    local inventory, inventory_err = listTree(path)
    if not inventory then return false, inventory_err end
    local actual = {}
    local marker_file_seen = false
    for _, item in ipairs(inventory) do
        local top_level = item.path:match("^[^/]+")
        if not allowed[top_level] then
            return false, invalidOutputInventory(path, "Generated output contains an unexpected top-level entry", {
                unexpected_path = normalizePath(path .. "/" .. item.path),
            })
        end
        if item.path == GENERATED_MARKER_RELATIVE then
            if item.kind ~= "file" then
                return false, invalidOutputInventory(path, "Generated output marker is not a regular file", {
                    unexpected_path = normalizePath(path .. "/" .. item.path),
                })
            end
            marker_file_seen = true
        else
            actual[item.path] = item
        end
    end
    if not marker_file_seen then
        return false, invalidOutputInventory(path, "Generated output marker is absent from the output tree")
    end

    for relative, expected in pairs(marker.entries) do
        local item = actual[relative]
        if not item or item.kind ~= expected.kind
            or (item.kind == "file" and item.hash ~= expected.hash) then
            return false, invalidOutputInventory(path, "Generated output no longer matches its ownership marker", {
                unexpected_path = normalizePath(path .. "/" .. relative),
            })
        end
    end
    for relative in pairs(actual) do
        if marker.entries[relative] == nil then
            return false, invalidOutputInventory(path, "Generated output contains unowned nested content", {
                unexpected_path = normalizePath(path .. "/" .. relative),
            })
        end
    end
    return true, marker
end

local function writeGeneratedMarker(path, declared_output_dir)
    local marker_path = normalizePath(path .. "/" .. GENERATED_MARKER_RELATIVE)
    if pathExists(marker_path) or isSymlink(marker_path) then
        return makeError("FilesystemError", "Staging output already contains a generated marker", {
            path = marker_path,
        })
    end
    local inventory, inventory_err = listTree(path)
    if not inventory then return inventory_err end
    local lines = {
        GENERATED_MARKER,
        "output_dir=" .. normalizePath(declared_output_dir or path),
    }
    for _, item in ipairs(inventory) do
        if item.kind == "dir" then
            lines[#lines + 1] = "dir\t" .. item.path
        else
            lines[#lines + 1] = "file\t" .. item.path .. "\t" .. item.hash
        end
    end
    return writeFile(marker_path, table.concat(lines, "\n") .. "\n")
end

local function validateLuaPrefix(prefix)
    if type(prefix) ~= "string" or prefix == "" then
        return makeError("ToolchainError", "Lua prefix is required for this onedir target")
    end
    local include = normalizePath(prefix .. "/include/lua.h")
    local liblua = normalizePath(prefix .. "/lib/liblua.a")
    if not fileExists(include) or not fileExists(liblua) then
        return makeError("ToolchainError", "Lua prefix must contain include/lua.h and lib/liblua.a", {
            lua_prefix = prefix,
        })
    end
    return nil
end

local function validateWindowsLuaPrefix(prefix, lua_version)
    if type(prefix) ~= "string" or prefix == "" then
        return makeError("ToolchainError", "Lua prefix is required for windows onedir target")
    end
    local include = normalizePath(prefix .. "/include/lua.h")
    if not fileExists(include) then
        return makeError("ToolchainError", "Windows Lua prefix must contain include/lua.h", {
            lua_prefix = prefix,
        })
    end
    local compact_abi = string.format("lua%d%d.dll", lua_version.major, lua_version.minor)
    local dotted_abi = string.format("lua%d.%d.dll", lua_version.major, lua_version.minor)
    local candidates = {}
    for _, name in ipairs({ compact_abi, dotted_abi }) do
        candidates[#candidates + 1] = normalizePath(prefix .. "/bin/" .. name)
        candidates[#candidates + 1] = normalizePath(prefix .. "/" .. name)
    end
    for _, candidate in ipairs(candidates) do
        if fileExists(candidate) then
            return nil, {
                include_dir = normalizePath(prefix .. "/include"),
                dll_path = candidate,
                dll_dir = dirname(candidate),
                dll_name = basename(candidate),
                library_name = (basename(candidate):gsub("%.dll$", "")),
            }
        end
    end
    return makeError("ToolchainError", "Windows Lua prefix does not contain the selected Lua ABI DLL", {
        lua_prefix = prefix,
        lua_abi = lua_version.abi,
        candidates = candidates,
    })
end

writeFile = function(path, content)
    local ok, write_err = fs.writeFile(path, content or "")
    if ok then return nil end
    return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
        path = path,
        cause = write_err,
    })
end

local function copyFile(source, destination, expected_hash, hash_algorithm)
    local dir_err = ensureDirectory(dirname(destination))
    if dir_err then
        return dir_err
    end
    local ok, output = commandOutput("cp " .. shellQuote(source) .. " " .. shellQuote(destination))
    if not ok then
        return makeError("FilesystemError", "Cannot copy file: " .. tostring(source), {
            source = source,
            destination = destination,
            output = output,
        })
    end
    if expected_hash ~= nil then
        local copied, read_err = fs.readRegularFile(destination)
        if copied == nil then
            return sourceChangedError(source, expected_hash, nil, hash_algorithm, {
                destination_path = destination,
                cause = read_err,
            })
        end
        local actual_hash, hash_err = contentHash(copied, hash_algorithm)
        if hash_err then return hash_err end
        if actual_hash ~= expected_hash then
            return sourceChangedError(source, expected_hash, actual_hash, hash_algorithm, {
                destination_path = destination,
            })
        end
    end
    return nil
end

local function findLinkedLuaRuntime(exe_path)
    local ok, output = commandOutput("ldd " .. shellQuote(exe_path))
    if not ok then
        return nil, output
    end
    for line in output:gmatch("[^\n]+") do
        local name, path = line:match("^%s*(liblua[^%s]*)%s+=>%s+([^%s]+)")
        if name and path and path ~= "not" then
            return path, name
        end
        path = line:match("^%s*(/[^%s]*liblua[^%s]*)")
        if path then
            return path, basename(path)
        end
    end
    return nil, output
end

local function copyLuaRuntime(exe_path, native_dir)
    local lua_path, lua_name = findLinkedLuaRuntime(exe_path)
    if not lua_path then
        return makeError("LuaRuntimeNotFoundError", "Cannot locate linked Lua shared library", {
            executable = exe_path,
            output = lua_name,
        })
    end
    local destination = normalizePath(native_dir .. "/" .. lua_name)
    if pathExists(destination) or isSymlink(destination) then
        return makeError("DuplicateModuleError", "Lua runtime destination collides with a native module", {
            source_path = normalizePath(lua_path),
            destination_path = destination,
        })
    end
    local err = copyFile(lua_path, destination)
    if err then
        return err
    end
    return nil, {
        source_path = normalizePath(lua_path),
        destination_path = normalizePath(".luai/native/" .. lua_name),
    }
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left < right
        end
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function isArray(tbl)
    local count = 0
    local max_index = 0
    for key in pairs(tbl) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
        if key > max_index then
            max_index = key
        end
    end
    return max_index == count
end

local function serializeValue(value, indent)
    indent = indent or ""
    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if value_type == "nil" then
        return "nil"
    end
    if value_type ~= "table" then
        return string.format("%q", tostring(value))
    end

    local child_indent = indent .. "    "
    local lines = { "{" }
    if isArray(value) then
        for i = 1, #value do
            lines[#lines + 1] = child_indent .. serializeValue(value[i], child_indent) .. ","
        end
    else
        for _, key in ipairs(sortedKeys(value)) do
            local key_text
            if type(key) == "string" and key:match("^[%a_][%w_]*$") then
                key_text = key
            else
                key_text = "[" .. serializeValue(key, child_indent) .. "]"
            end
            lines[#lines + 1] = child_indent .. key_text .. " = " .. serializeValue(value[key], child_indent) .. ","
        end
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end

local function serializeManifest(manifest)
    return "-- generated by luainstaller\nreturn " .. serializeValue(manifest, "")
end

local function selectedLuaVersion(manifest)
    local current = manifest and manifest.lua or compat.luaVersion()
    local major = tonumber(current and current.major)
    local minor = tonumber(current and current.minor)
    if not major or not minor then
        major, minor = tostring(current and current.version or ""):match("Lua%s+(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
    end
    if major ~= 5 or not minor or minor < 1 then
        return nil, makeError("UnsupportedLuaVersionError", "Bundle manifest requires an official Lua 5.1+ ABI", {
            lua_version = current and current.version,
        })
    end
    return {
        version = string.format("Lua %d.%d", major, minor),
        major = major,
        minor = minor,
        num = tonumber(current.num) or (major * 100 + minor),
        abi = current.abi or string.format("lua%d.%d", major, minor),
    }
end

local function abiProbeSource(lua_version)
    local source = [[
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM != @LUA_VERSION_NUM@
#error "luainstaller was generated for a different Lua ABI"
#endif

int main(void) {
    lua_State *state = luaL_newstate();
    const char *version;
    int matches;
    if (!state) return 70;
    luaL_openlibs(state);
    lua_getglobal(state, "_VERSION");
    version = lua_tostring(state, -1);
    matches = version != NULL && strcmp(version, "@LUA_VERSION@") == 0;
    if (!matches) {
        fprintf(stderr, "expected linked @LUA_VERSION@ runtime, got %s\n",
                version != NULL ? version : "unknown");
    }
    lua_pop(state, 1);
    lua_close(state);
    return matches ? 0 : 42;
}
]]
    source = source:gsub("@LUA_VERSION_NUM@", tostring(lua_version.num))
    source = source:gsub("@LUA_VERSION@", lua_version.version)
    return source
end

local function executableName(out_path, entry, profile)
    local name = basename(out_path or "")
    if name == "" or name == "." then
        name = stem(entry)
    end
    local suffix = profile and profile.executable_suffix or ""
    if suffix ~= "" and not name:lower():match(suffix:gsub("%.", "%%.") .. "$") then
        name = name .. suffix
    elseif IS_WINDOWS and suffix == "" and not name:lower():match("%.exe$") then
        name = name .. ".exe"
    end
    return name
end

local function windowsCompiler()
    return os.getenv("LUAI_WINDOWS_CC") or os.getenv("LUAI_CC") or os.getenv("CC") or "cc"
end

local function defaultOut(entry)
    return normalizePath("build/" .. stem(entry))
end

local function uniqueSiblingPath(final_path, label)
    local parent = dirname(final_path)
    local output_id = hash_mod.sha256(normalizePath(final_path)):sub(1, 24)
    for _ = 1, 20 do
        local suffix = tostring(os.time())
            .. tostring(os.clock()):gsub("%.", "")
            .. "-"
            .. tostring(math.random(100000, 999999))
        local candidate = normalizePath(parent .. "/.luai-" .. label .. "-"
            .. output_id .. "-" .. suffix)
        if not pathExists(candidate) then
            return candidate
        end
    end
    return nil
end

local function secureToken(context)
    local handle, open_err = io.open("/dev/urandom", "rb")
    if not handle then
        return nil, tostring(open_err or "cannot open /dev/urandom")
    end
    local bytes, read_err = handle:read(32)
    local closed, close_err = handle:close()
    if type(bytes) ~= "string" or #bytes ~= 32 or not closed then
        return nil, tostring(read_err or close_err or "short read from /dev/urandom")
    end
    return hash_mod.sha256(tostring(context or "") .. "\0" .. bytes)
end

local function removeDirectoryOnly(path_value)
    local ok, output = commandOutput("rmdir " .. shellQuote(path_value))
    if ok then
        return true
    end
    return nil, output
end

local function createStagingDirectory(final_path)
    local parent_err = ensureDirectory(dirname(final_path))
    if parent_err then
        return nil, parent_err
    end
    for _ = 1, 20 do
        local candidate = uniqueSiblingPath(final_path, "staging")
        if not candidate then
            break
        end
        local ok, output = commandOutput("mkdir -m 700 " .. shellQuote(candidate))
        if ok then
            return candidate
        end
        if not pathExists(candidate) then
            return nil, makeError("FilesystemError", "Cannot create staging directory", {
                path = candidate,
                output = output,
            })
        end
    end
    return nil, makeError("FilesystemError", "Cannot create unique staging directory", {
        path = final_path,
    })
end

local function acquireOutputLock(final_path)
    local parent_err = ensureDirectory(dirname(final_path))
    if parent_err then
        return nil, parent_err
    end
    local lock_id = hash_mod.sha256(normalizePath(final_path))
    local lock_path = normalizePath(dirname(final_path) .. "/.luai-lock-" .. lock_id)
    local token, token_err = secureToken(final_path)
    local release_token, release_token_err = secureToken(final_path .. "\0release")
    if not token or not release_token then
        return nil, makeError("FilesystemError", "Cannot generate secure output lock ownership", {
            path = final_path,
            lock_path = lock_path,
            output = token_err or release_token_err,
        })
    end
    local ok, output = commandOutput("mkdir -m 700 " .. shellQuote(lock_path))
    if not ok then
        return nil, makeError("FilesystemError", "Another build is using this output path, or a stale build lock remains", {
            path = final_path,
            lock_path = lock_path,
            output = output,
        })
    end
    local owner_path = normalizePath(lock_path .. "/owner." .. token)
    local owner_content = "token=" .. token .. "\noutput=" .. normalizePath(final_path) .. "\n"
    local wrote, write_err = fs.writeFile(owner_path, owner_content)
    if not wrote then
        return nil, makeError("FilesystemError", "Cannot record output lock ownership", {
            path = final_path,
            lock_path = lock_path,
            owner_path = owner_path,
            output = write_err,
            cleanup_error = "lock retained because ownership could not be proven",
        })
    end
    return {
        path = lock_path,
        owner_path = owner_path,
        owner_content = owner_content,
        token = token,
        release_token = release_token,
    }
end

local function restoreMovedOutputLock(release_path, lock_path)
    if pathExists(lock_path) or isSymlink(lock_path) then
        return false, "public lock path is already occupied"
    end
    local reserved, reserve_err = commandOutput("mkdir -m 700 " .. shellQuote(lock_path))
    if not reserved then
        return false, reserve_err
    end
    local restored, restore_err = os.rename(release_path, lock_path)
    if not restored then
        return false, restore_err
    end
    return true
end

local function releaseOutputLock(lock, failure)
    local cleanup_err
    if lock then
        local release_path = normalizePath(dirname(lock.path)
            .. "/.luai-lock-release-" .. lock.release_token)
        if pathExists(release_path) or isSymlink(release_path) then
            cleanup_err = makeError("FilesystemError", "Output lock release path already exists", {
                lock_path = lock.path,
                release_path = release_path,
            })
        else
            local moved, move_err = os.rename(lock.path, release_path)
            if not moved then
                cleanup_err = makeError("FilesystemError", "Cannot bind output lock for release", {
                    lock_path = lock.path,
                    release_path = release_path,
                    output = tostring(move_err),
                })
            end
        end
        local release_owner = normalizePath(release_path .. "/owner." .. lock.token)
        local owner_content, read_err
        if not cleanup_err then
            owner_content, read_err = fs.readRegularFile(release_owner)
        end
        if not cleanup_err and owner_content ~= lock.owner_content then
            local restored, restore_err
            restored, restore_err = restoreMovedOutputLock(release_path, lock.path)
            cleanup_err = makeError("FilesystemError", "Output lock ownership changed before release", {
                lock_path = lock.path,
                release_path = release_path,
                owner_path = release_owner,
                output = read_err,
                restored = restored and true or false,
                restore_error = restored and nil or tostring(restore_err),
            })
        elseif not cleanup_err then
            local removed_owner, owner_err = os.remove(release_owner)
            if not removed_owner then
                cleanup_err = makeError("FilesystemError", "Cannot remove output lock owner record", {
                    lock_path = lock.path,
                    release_path = release_path,
                    owner_path = release_owner,
                    output = tostring(owner_err),
                })
            else
                local removed_lock, lock_err = removeDirectoryOnly(release_path)
                if not removed_lock then
                    cleanup_err = makeError("FilesystemError", "Cannot remove non-empty or replaced output lock", {
                        lock_path = lock.path,
                        release_path = release_path,
                        output = tostring(lock_err),
                    })
                end
            end
        end
    end
    if cleanup_err and failure and failure.error then
        failure.error.cleanup_error = cleanup_err.error and cleanup_err.error.message or tostring(cleanup_err)
        failure.error.cleanup_path = lock and lock.path or nil
        return failure
    end
    return failure or cleanup_err
end

local function captureOutputSnapshot(path_value)
    if not pathExists(path_value) then
        return { kind = "absent" }
    end
    local inventory, inventory_err = listTree(path_value)
    if not inventory then return nil, inventory_err end
    if #inventory == 0 then
        return { kind = "empty" }
    end
    local marker, read_err = fs.readFile(normalizePath(path_value .. "/" .. GENERATED_MARKER_RELATIVE))
    if marker == nil then
        return nil, invalidOutputInventory(path_value, "Cannot snapshot generated output marker", {
            cause = read_err,
        })
    end
    return {
        kind = "generated",
        marker_hash = hash_mod.sha256(marker),
    }
end

local function outputSnapshotMatches(path_value, allowed, snapshot, declared_output_dir)
    local validation_err = validateOutputDirectory(path_value, allowed, declared_output_dir)
    if validation_err then
        return false, validation_err
    end
    local current, snapshot_err = captureOutputSnapshot(path_value)
    if not current then return false, snapshot_err end
    if current.kind ~= snapshot.kind
        or current.marker_hash ~= snapshot.marker_hash then
        return false, makeError("InvalidOutputError", "Output changed while the bundle was being built", {
            path = path_value,
            initial_state = snapshot.kind,
            current_state = current.kind,
        })
    end
    return true
end

local function removeGeneratedBackup(path_value, allowed, snapshot, declared_output_dir)
    if snapshot.kind == "empty" then
        local removed, remove_err = removeDirectoryOnly(path_value)
        if not removed then
            return makeError("FilesystemError", "Previous empty output backup is no longer empty", {
                path = path_value,
                output = tostring(remove_err),
            })
        end
        return nil
    end
    if snapshot.kind ~= "generated" then
        return makeError("InvalidOutputError", "Refusing to remove a backup with an unknown ownership state", {
            path = path_value,
            snapshot_kind = snapshot.kind,
        })
    end

    local matches, marker_or_err = generatedMarkerMatches(path_value, allowed, declared_output_dir)
    if not matches then return marker_or_err end
    local marker = marker_or_err
    local marker_path = normalizePath(path_value .. "/" .. GENERATED_MARKER_RELATIVE)
    local marker_content, marker_read_err = fs.readRegularFile(marker_path)
    if marker_content == nil or hash_mod.sha256(marker_content) ~= snapshot.marker_hash then
        return invalidOutputInventory(path_value, "Generated output marker changed before backup cleanup", {
            unexpected_path = marker_path,
            cause = marker_read_err,
        })
    end

    local cleanup_nonce, nonce_err = secureToken(path_value)
    if not cleanup_nonce then
        return makeError("FilesystemError", "Cannot generate a secure backup quarantine name", {
            path = path_value,
            output = nonce_err,
        })
    end
    cleanup_nonce = cleanup_nonce:sub(1, 24)
    local cleanup_index = 0
    local function removeOwnedRegular(candidate, expected_hash)
        local quarantine_path
        for _ = 1, 20 do
            cleanup_index = cleanup_index + 1
            quarantine_path = normalizePath(dirname(candidate) .. "/.luai-remove-"
                .. cleanup_nonce .. "-" .. tostring(cleanup_index))
            if not pathExists(quarantine_path) and not isSymlink(quarantine_path) then
                break
            end
            quarantine_path = nil
        end
        if not quarantine_path then
            return makeError("FilesystemError", "Cannot allocate a backup-file quarantine path", {
                path = candidate,
            })
        end
        local moved, move_err = os.rename(candidate, quarantine_path)
        if not moved then
            return makeError("FilesystemError", "Cannot quarantine an owned backup file", {
                path = candidate,
                quarantine_path = quarantine_path,
                output = tostring(move_err),
            })
        end
        local content, read_err = fs.readRegularFile(quarantine_path)
        if content == nil or hash_mod.sha256(content) ~= expected_hash then
            return invalidOutputInventory(path_value, "Backup file changed while it was quarantined", {
                unexpected_path = candidate,
                preserved_path = quarantine_path,
                cause = read_err,
            })
        end
        local removed, remove_err = os.remove(quarantine_path)
        if not removed then
            return makeError("FilesystemError", "Cannot remove a verified quarantined backup file", {
                path = candidate,
                quarantine_path = quarantine_path,
                output = tostring(remove_err),
            })
        end
        return nil
    end

    local files = {}
    local directories = {}
    for _, item in pairs(marker.entries) do
        if item.kind == "file" then
            files[#files + 1] = item
        else
            directories[#directories + 1] = item
        end
    end
    table.sort(files, function(left, right)
        return left.path < right.path
    end)
    table.sort(directories, function(left, right)
        local left_depth = select(2, left.path:gsub("/", ""))
        local right_depth = select(2, right.path:gsub("/", ""))
        if left_depth ~= right_depth then
            return left_depth > right_depth
        end
        return left.path > right.path
    end)

    for _, item in ipairs(files) do
        local candidate = normalizePath(path_value .. "/" .. item.path)
        local content, read_err = fs.readRegularFile(candidate)
        if content == nil or hash_mod.sha256(content) ~= item.hash then
            return invalidOutputInventory(path_value, "Generated backup file changed during cleanup", {
                unexpected_path = candidate,
                cause = read_err,
            })
        end
        local remove_err = removeOwnedRegular(candidate, item.hash)
        if remove_err then return remove_err end
    end

    local current_marker, current_marker_err = fs.readRegularFile(marker_path)
    if current_marker == nil or hash_mod.sha256(current_marker) ~= snapshot.marker_hash then
        return invalidOutputInventory(path_value, "Generated output marker changed during backup cleanup", {
            unexpected_path = marker_path,
            cause = current_marker_err,
        })
    end
    local marker_remove_err = removeOwnedRegular(marker_path, snapshot.marker_hash)
    if marker_remove_err then return marker_remove_err end

    for _, item in ipairs(directories) do
        local candidate = normalizePath(path_value .. "/" .. item.path)
        local removed, remove_err = removeDirectoryOnly(candidate)
        if not removed then
            return makeError("FilesystemError", "Cannot remove a non-empty or changed backup directory", {
                path = candidate,
                output = tostring(remove_err),
            })
        end
    end
    local removed_root, root_remove_err = removeDirectoryOnly(path_value)
    if not removed_root then
        return makeError("FilesystemError", "Cannot remove a non-empty or changed output backup", {
            path = path_value,
            output = tostring(root_remove_err),
        })
    end
    return nil
end

local function commitStagingDirectory(stage_path, final_path, allowed, snapshot)
    local unchanged, changed_err = outputSnapshotMatches(final_path, allowed, snapshot)
    if not unchanged then
        return changed_err
    end
    local backup_path
    if pathExists(final_path) then
        backup_path = uniqueSiblingPath(final_path, "backup")
        if not backup_path then
            return makeError("FilesystemError", "Cannot allocate output backup path", {
                path = final_path,
            })
        end
        local renamed, rename_err = os.rename(final_path, backup_path)
        if not renamed then
            return makeError("FilesystemError", "Cannot preserve previous output directory", {
                path = final_path,
                backup_path = backup_path,
                output = tostring(rename_err),
            })
        end
        local moved_unchanged, moved_err = outputSnapshotMatches(
            backup_path,
            allowed,
            snapshot,
            final_path
        )
        if not moved_unchanged then
            local restored, restore_err = os.rename(backup_path, final_path)
            if moved_err and moved_err.error then
                moved_err.error.path = final_path
                moved_err.error.backup_path = backup_path
                moved_err.error.restored = restored and true or false
                moved_err.error.restore_error = restored and nil or tostring(restore_err)
            end
            return moved_err or makeError(
                "InvalidOutputError",
                "Output changed while it was being moved to a backup",
                {
                    path = final_path,
                    backup_path = backup_path,
                    restored = restored and true or false,
                    restore_error = restored and nil or tostring(restore_err),
                }
            )
        end
    end

    local committed, commit_err = os.rename(stage_path, final_path)
    if not committed then
        local restore_err
        if backup_path then
            local restored
            restored, restore_err = os.rename(backup_path, final_path)
            if restored then
                restore_err = nil
            end
        end
        return makeError("FilesystemError", "Cannot install completed output directory", {
            path = final_path,
            staging_path = stage_path,
            output = tostring(commit_err),
            restore_error = restore_err and tostring(restore_err) or nil,
        })
    end

    if backup_path then
        local still_unchanged, backup_changed_err = outputSnapshotMatches(
            backup_path,
            allowed,
            snapshot,
            final_path
        )
        if not still_unchanged then
            local staged_again, stage_restore_err = os.rename(final_path, stage_path)
            local restored, restore_err
            if staged_again then
                restored, restore_err = os.rename(backup_path, final_path)
            end
            if backup_changed_err and backup_changed_err.error then
                backup_changed_err.error.path = final_path
                backup_changed_err.error.backup_path = backup_path
                backup_changed_err.error.restored = restored and true or false
                backup_changed_err.error.committed = not staged_again
                backup_changed_err.error.restore_error = restored and nil
                    or tostring(restore_err or stage_restore_err)
            end
            return backup_changed_err or makeError(
                "InvalidOutputError",
                "Previous output changed before its backup could be removed",
                {
                    path = final_path,
                    backup_path = backup_path,
                    restored = restored and true or false,
                    committed = not staged_again,
                    restore_error = restored and nil
                        or tostring(restore_err or stage_restore_err),
                }
            )
        end
        local cleanup_err = removeGeneratedBackup(backup_path, allowed, snapshot, final_path)
        if cleanup_err then
            cleanup_err.error = cleanup_err.error or {}
            cleanup_err.error.path = final_path
            cleanup_err.error.backup_path = backup_path
            cleanup_err.error.committed = true
            return cleanup_err
        end
    end
    return nil
end

local function unsafeOutputError(path)
    return makeError("InvalidOutputError", "Refusing to overwrite unsafe output directory: " .. tostring(path), {
        path = path,
    })
end

local function validateOutputLocation(path)
    local normalized = normalizePath(path)
    if normalized == "/" or normalized == "//" or normalized == "." or normalized == ""
        or normalized:match("^%a:/$") then
        return unsafeOutputError(path)
    end
    if normalized == currentDirectory() then
        return unsafeOutputError(path)
    end
    if isSymlink(normalized) then
        return unsafeOutputError(path)
    end
    if pathExists(normalized) then
        if not directoryExists(normalized) then
            return makeError("InvalidOutputError", "Output path exists and is not a directory: " .. tostring(path), {
                path = path,
            })
        end
    end
    return nil
end

validateOutputDirectory = function(path, allowed_generated_entries, declared_output_dir)
    local location_err = validateOutputLocation(path)
    if location_err then
        return location_err
    end
    local normalized = normalizePath(path)
    if pathExists(normalized) then
        local inventory, inventory_err = listTree(normalized)
        if not inventory then return inventory_err end
        if #inventory > 0 then
            local marker_ok, marker_or_err = generatedMarkerMatches(
                normalized,
                allowed_generated_entries or {},
                declared_output_dir
            )
            if not marker_ok then return marker_or_err end
        end
    end
    return nil
end

local function traceModuleMaps(trace)
    local lua_names = {}
    local native_names = {}
    local function addAlias(target, source_path, requested)
        if type(requested) ~= "string" or requested == "" then
            return
        end
        source_path = normalizePath(source_path)
        local aliases = target[source_path]
        if not aliases then
            aliases = {}
            target[source_path] = aliases
        end
        aliases[requested] = true
    end
    for _, item in ipairs(trace or {}) do
        if item.selected_path and item.requested then
            if item.classification == "lua" or item.selected_type == "lua" then
                addAlias(lua_names, item.selected_path, item.requested)
            elseif item.classification == "native" or item.selected_type == "native" then
                addAlias(native_names, item.selected_path, item.requested)
            end
        end
    end
    return lua_names, native_names
end

local function validateModuleAliasOwners(lua_names, native_names)
    local owners = {}
    local function addAliases(kind, aliases_by_source)
        local sources = {}
        for source_path in pairs(aliases_by_source) do
            sources[#sources + 1] = source_path
        end
        table.sort(sources)
        for _, source_path in ipairs(sources) do
            local aliases = {}
            for module_name, enabled in pairs(aliases_by_source[source_path]) do
                if enabled then aliases[#aliases + 1] = module_name end
            end
            table.sort(aliases)
            for _, module_name in ipairs(aliases) do
                local owner = owners[module_name]
                if owner and (owner.source ~= source_path or owner.kind ~= kind) then
                    return makeError(
                        "DuplicateModuleError",
                        "Module alias is owned by multiple sources: " .. module_name,
                        {
                            module_name = module_name,
                            first_source = owner.source,
                            first_kind = owner.kind,
                            second_source = source_path,
                            second_kind = kind,
                        }
                    )
                end
                owners[module_name] = {
                    source = source_path,
                    kind = kind,
                }
            end
        end
        return nil
    end
    return addAliases("lua", lua_names) or addAliases("native", native_names)
end

local function nativeDestinations(native_path, module_names, native_dir, target_os)
    local destinations = {}
    local seen = {}
    local function add(candidate)
        candidate = normalizePath(candidate)
        if not isWithin(candidate, native_dir) then
            return makeError("InvalidOptionsError", "Native module destination escapes .luai/native", {
                destination = candidate,
                native_dir = native_dir,
                module_names = module_names,
            })
        end
        local prefix = normalizePath(native_dir) .. "/"
        local relative = candidate:sub(#prefix + 1)
        local valid, reason = validateTargetRelative(relative, target_os)
        if not valid then
            return makeError("InvalidOptionsError", "Invalid native target path: " .. tostring(relative), {
                destination = candidate,
                target_path = relative,
                target_os = target_os,
                reason = reason,
            })
        end
        if not seen[candidate] then
            seen[candidate] = true
            destinations[#destinations + 1] = candidate
        end
        return nil
    end

    local err = add(native_dir .. "/" .. basename(native_path))
    if err then
        return nil, err
    end
    local aliases = {}
    if type(module_names) == "string" then
        aliases[1] = module_names
    elseif type(module_names) == "table" then
        for module_name, enabled in pairs(module_names) do
            if enabled then aliases[#aliases + 1] = module_name end
        end
        table.sort(aliases)
    end
    for _, module_name in ipairs(aliases) do
        if type(module_name) ~= "string" or module_name == "" then
            return nil, makeError("InvalidOptionsError", "Native module name must be a non-empty string", {
                module_name = module_name,
            })
        end
        if module_name:find("[/\\]", 1) then
            return nil, makeError("InvalidOptionsError", "Native module name must not contain path separators", {
                module_name = module_name,
            })
        end
        local nested = module_name:gsub("%.", "/")
        if not isSafeRelative(nested) then
            return nil, makeError("InvalidOptionsError", "Native module name is not a safe relative path", {
                module_name = module_name,
            })
        end
        local ext = basename(native_path):match("(%.[^%.]+)$") or ".so"
        err = add(native_dir .. "/" .. nested .. ext)
        if err then
            return nil, err
        end
    end
    return destinations
end

local function validateTargetTree(root, target_os)
    local inventory, inventory_err = listTree(root)
    if not inventory then return inventory_err end
    local owners = {}
    for _, item in ipairs(inventory) do
        local valid, reason = validateTargetRelative(item.path, target_os)
        if not valid then
            return makeError("InvalidOptionsError", "Generated target path is not portable: " .. item.path, {
                target_path = item.path,
                target_os = target_os,
                reason = reason,
            })
        end
        local key = targetKey(item.path, target_os)
        local owner = owners[key]
        if owner and owner ~= item.path then
            return makeError("DuplicateModuleError", "Generated target paths collide: "
                .. owner .. " and " .. item.path, {
                first_destination = owner,
                second_destination = item.path,
                target_os = target_os,
            })
        end
        owners[key] = item.path
    end
    return nil
end

function M.bundleOnedir(opts)
    opts = opts or {}
    local manifest = opts.manifest
    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local entry = opts.entry
    if type(manifest) ~= "table" then
        return makeError("InvalidOptionsError", "manifest is required")
    end
    if type(entry) ~= "string" or entry == "" then
        return makeError("InvalidOptionsError", "entry is required")
    end
    local lua_version, lua_version_err = selectedLuaVersion(manifest)
    if not lua_version then
        return lua_version_err
    end
    local lua_names, native_names = traceModuleMaps(opts.trace or manifest.trace or {})
    local alias_err = validateModuleAliasOwners(lua_names, native_names)
    if alias_err then
        return alias_err
    end

    local final_out_dir = absolutePath(opts.out or defaultOut(entry))
    local location_err = validateOutputLocation(final_out_dir)
    if location_err then
        return location_err
    end

    if type(io.popen) ~= "function" then
        return makeError("ToolchainError", "io.popen is required to build onedir bundles")
    end

    local profile, profile_err = platform.profile({
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    if not profile then return profile_err end
    local native_toolchain
    if profile.target_os ~= "windows" then
        local toolchain_err
        native_toolchain, toolchain_err = toolchain.resolve({
            target_os = profile.target_os,
            target_arch = profile.target_arch,
            lua_prefix = profile.lua_prefix,
            lua_version = lua_version,
        })
        if not native_toolchain then return toolchain_err end
    end
    local windows_lua
    if profile.target_os == "windows" then
        return makeError("UnsupportedPlatformError", "native Windows bundling is not yet initialized")
    elseif profile.target_os == "macos" then
        local prefix_err = validateLuaPrefix(profile.lua_prefix)
        if prefix_err then
            return prefix_err
        end
    end
    if profile.target_os == "windows" then
        -- Convention: success is (nil, data); failure is a single error table.
        local windows_prefix_error
        windows_prefix_error, windows_lua = validateWindowsLuaPrefix(profile.lua_prefix, lua_version)
        if windows_prefix_error then
            return windows_prefix_error
        end
        local cc_ok, cc_output = commandOutput(shellQuote(windowsCompiler()) .. " --version")
        if not cc_ok then
            return makeError("ToolchainError", "Windows onedir bundling requires a native C compiler", {
                output = cc_output,
            })
        end
    end

    local exe_name = executableName(final_out_dir, entry, profile)
    local exe_valid, exe_reason = validateTargetRelative(exe_name, profile.target_os)
    if not exe_valid then
        return makeError("InvalidOptionsError", "Executable name is not portable for the target: " .. exe_name, {
            target_path = exe_name,
            target_os = profile.target_os,
            reason = exe_reason,
        })
    end
    if targetKey(exe_name, profile.target_os) == targetKey(".luai", profile.target_os) then
        return makeError("InvalidOptionsError", "Executable name collides with the .luai metadata directory", {
            target_path = exe_name,
            target_os = profile.target_os,
        })
    end
    local allowed_generated_entries = {
        [".luai"] = true,
        [exe_name] = true,
    }
    if windows_lua then
        allowed_generated_entries[windows_lua.dll_name] = true
    end
    local output_err = validateOutputDirectory(final_out_dir, allowed_generated_entries)
    if output_err then
        return output_err
    end
    local output_lock, lock_err = acquireOutputLock(final_out_dir)
    if not output_lock then
        return lock_err
    end
    output_err = validateOutputDirectory(final_out_dir, allowed_generated_entries)
    if output_err then
        return releaseOutputLock(output_lock, output_err)
    end
    local output_snapshot, snapshot_err = captureOutputSnapshot(final_out_dir)
    if not output_snapshot then
        return releaseOutputLock(output_lock, snapshot_err)
    end

    local out_dir, stage_err = createStagingDirectory(final_out_dir)
    if not out_dir then
        return releaseOutputLock(output_lock, stage_err)
    end
    local function abandon(failure)
        local cleanup_err = removeTree(out_dir)
        if cleanup_err and failure and failure.error then
            failure.error.cleanup_error = cleanup_err.error and cleanup_err.error.message or tostring(cleanup_err)
            failure.error.cleanup_path = out_dir
        end
        return releaseOutputLock(output_lock, failure or cleanup_err)
    end

    local exe_path = normalizePath(out_dir .. "/" .. exe_name)
    local luai_dir = normalizePath(out_dir .. "/.luai")
    local native_dir = normalizePath(luai_dir .. "/native")
    local build_dir = normalizePath(luai_dir .. "/build")
    local c_path = normalizePath(build_dir .. "/launcher.c")

    local err = ensureDirectory(native_dir) or ensureDirectory(build_dir)
    if err then
        return abandon(err)
    end

    local source_hashes, source_hash_err = manifestSourceHashes(manifest)
    if not source_hashes then
        return abandon(source_hash_err)
    end
    local c_source
    local ok_generate, generated = pcall(launcher.generateSource, {
        entry = entry,
        dependencies = dependencies,
        module_names = lua_names,
        source_hashes = source_hashes,
        source_hash_algorithm = manifest.hash_algorithm,
        native_dir = ".luai/native",
        lua_version = lua_version,
    })
    if not ok_generate then
        return abandon(fromThrownError(generated))
    end
    c_source = generated

    err = writeFile(c_path, c_source)
    if err then
        return abandon(err)
    end

    local native_owners = {}
    for _, path in ipairs(dependencies.libraries or {}) do
        local normalized = normalizePath(path)
        local canonical = normalizePath(absolutePath(path))
        local expected_hash = source_hashes[canonical]
        if expected_hash == nil then
            return abandon(makeError("InvalidManifestError", "Manifest is missing a native source hash", {
                source_path = canonical,
            }))
        end
        local destinations, dest_err = nativeDestinations(
            normalized,
            native_names[canonical] or native_names[normalized],
            native_dir,
            profile.target_os
        )
        if not destinations then
            return abandon(dest_err)
        end
        for _, destination in ipairs(destinations) do
            local destination_key = targetKey(destination, profile.target_os)
            local owner = native_owners[destination_key]
            if owner and (owner.source ~= canonical or owner.path ~= destination) then
                return abandon(makeError("DuplicateModuleError", "Duplicate native destination: " .. destination, {
                    destination_path = destination,
                    first_destination = owner.path,
                    first_source = owner.source,
                    second_source = canonical,
                    target_os = profile.target_os,
                }))
            end
            native_owners[destination_key] = {
                source = canonical,
                path = destination,
            }
            err = copyFile(
                normalized,
                destination,
                expected_hash,
                manifest.hash_algorithm
            )
            if err then
                return abandon(err)
            end
        end
    end

    local function compileCommand(source_path, output_path)
        if profile.target_os == "windows" then
            return table.concat({
                shellQuote(windowsCompiler()),
                shellQuote(source_path),
                "-I" .. shellQuote(windows_lua.include_dir),
                "-L" .. shellQuote(windows_lua.dll_dir),
                "-o",
                shellQuote(output_path),
                "-static-libgcc",
                "-Wl,--no-insert-timestamp",
                "-l" .. windows_lua.library_name,
            }, " ")
        end
        return table.concat({
            shellQuote(native_toolchain.cc),
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            shellQuote(source_path),
            "-o",
            shellQuote(output_path),
            "-Wl,-rpath," .. shellQuote(profile.loader_rpath),
            table.concat(native_toolchain.link_args, " "),
        }, " ")
    end

    local compile_cmd = compileCommand(c_path, exe_path)
    local compile_ok, compile_output = commandOutput(compile_cmd)
    if not compile_ok then
        return abandon(makeError("CompilationFailedError", "C launcher compilation failed", {
            command = compile_cmd,
            output = compile_output,
        }))
    end

    if profile.target_os ~= "windows" then
        local chmod_ok, chmod_output = commandOutput("chmod +x " .. shellQuote(exe_path))
        if not chmod_ok then
            return abandon(makeError("FilesystemError", "Cannot mark launcher executable", {
                path = exe_path,
                output = chmod_output,
            }))
        end
    end

    if profile.target_os == "windows" then
        local exe_dll = normalizePath(out_dir .. "/" .. windows_lua.dll_name)
        err = copyFile(windows_lua.dll_path, exe_dll)
        if err then
            return abandon(err)
        end
        local native_dll = normalizePath(native_dir .. "/" .. windows_lua.dll_name)
        if pathExists(native_dll) or isSymlink(native_dll) then
            return abandon(makeError(
                "DuplicateModuleError",
                "Lua runtime destination collides with a native module",
                {
                    source_path = normalizePath(windows_lua.dll_path),
                    destination_path = native_dll,
                }
            ))
        end
        err = copyFile(windows_lua.dll_path, native_dll)
        if err then
            return abandon(err)
        end
        manifest.launcher.lua_runtime = {
            source_path = normalizePath(windows_lua.dll_path),
            destination_path = windows_lua.dll_name,
            native_destination_path = normalizePath(".luai/native/" .. windows_lua.dll_name),
            link_mode = "shared-dll",
        }
    elseif profile.target_os == "macos" then
        manifest.launcher.lua_runtime = {
            source_path = normalizePath(profile.lua_prefix .. "/lib/liblua.a"),
            destination_path = nil,
            link_mode = "static",
        }
    else
        local runtime_record
        err, runtime_record = copyLuaRuntime(exe_path, native_dir)
        if err then
            return abandon(err)
        end
        manifest.launcher.lua_runtime = runtime_record
    end

    local abi_probe_c = normalizePath(build_dir .. "/lua-abi-probe.c")
    local abi_probe_exe = normalizePath(
        build_dir .. "/lua-abi-probe" .. (profile.target_os == "windows" and ".exe" or "")
    )
    err = writeFile(abi_probe_c, abiProbeSource(lua_version))
    if err then
        return abandon(err)
    end
    local abi_compile_cmd = compileCommand(abi_probe_c, abi_probe_exe)
    local abi_compile_ok, abi_compile_output = commandOutput(abi_compile_cmd)
    if not abi_compile_ok then
        return abandon(makeError("ToolchainError", "Cannot compile the linked Lua runtime ABI probe", {
            command = abi_compile_cmd,
            output = abi_compile_output,
        }))
    end
    if profile.target_os ~= "windows" then
        local probe_mode_ok, probe_mode_output = commandOutput(
            "chmod +x " .. shellQuote(abi_probe_exe)
        )
        if not probe_mode_ok then
            return abandon(makeError("FilesystemError", "Cannot mark the Lua ABI probe executable", {
                path = abi_probe_exe,
                output = probe_mode_output,
            }))
        end
    end
    local abi_probe_runtime
    if profile.target_os == "windows" then
        abi_probe_runtime = normalizePath(build_dir .. "/" .. windows_lua.dll_name)
        err = copyFile(windows_lua.dll_path, abi_probe_runtime)
        if err then return abandon(err) end
    end
    local abi_run_cmd
    if profile.target_os == "windows" then
        abi_run_cmd = shellQuote(abi_probe_exe)
    elseif profile.target_os ~= "macos" then
        local library_path = native_dir
        local inherited_library_path = os.getenv("LD_LIBRARY_PATH")
        if inherited_library_path and inherited_library_path ~= "" then
            library_path = library_path .. ":" .. inherited_library_path
        end
        abi_run_cmd = "LD_LIBRARY_PATH=" .. shellQuote(library_path)
            .. " " .. shellQuote(abi_probe_exe)
    else
        abi_run_cmd = shellQuote(abi_probe_exe)
    end
    local abi_ok, abi_output = commandOutput(abi_run_cmd)
    if not abi_ok then
        return abandon(makeError("ToolchainError", "The linked Lua runtime does not match the selected Lua ABI", {
            command = abi_run_cmd,
            output = abi_output,
            expected = lua_version.version,
        }))
    end
    local removed_probe = os.remove(abi_probe_exe)
    local removed_probe_source = os.remove(abi_probe_c)
    local removed_probe_runtime = not abi_probe_runtime or os.remove(abi_probe_runtime)
    if not removed_probe or not removed_probe_source or not removed_probe_runtime then
        return abandon(makeError("FilesystemError", "Cannot remove the completed Lua ABI probe", {
            executable = abi_probe_exe,
            source = abi_probe_c,
            runtime = abi_probe_runtime,
        }))
    end

    err = verifyManifestSources(manifest)
    if err then
        return abandon(err)
    end
    err = writeFile(normalizePath(luai_dir .. "/manifest.lua"), serializeManifest(manifest))
    if err then
        return abandon(err)
    end
    err = validateTargetTree(out_dir, profile.target_os)
    if err then
        return abandon(err)
    end
    err = writeGeneratedMarker(out_dir, final_out_dir)
    if err then
        return abandon(err)
    end

    err = commitStagingDirectory(out_dir, final_out_dir, allowed_generated_entries, output_snapshot)
    if err then
        if not err.error or err.error.committed ~= true then
            return abandon(err)
        end
        return releaseOutputLock(output_lock, err)
    end

    local success = {
        ok = true,
        action = "bundle",
        mode = "onedir",
        entry = entry,
        out = final_out_dir,
        executable = normalizePath(final_out_dir .. "/" .. exe_name),
        manifest = manifest,
    }
    local release_err = releaseOutputLock(output_lock)
    if release_err then
        release_err.error.committed = true
        return release_err
    end
    return success
end

return M
