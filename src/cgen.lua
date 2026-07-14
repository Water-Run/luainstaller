--[[
Lua bootstrap generation for luainstaller bundles.

Author:
    WaterRun
File:
    cgen.lua
Date:
    2026-06-16
Updated:
    2026-07-11
]]

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")

local M = {}

local normalizePath = path.normalize
local absolutePath = path.absolute
local basename = path.basename

local function contentHash(content, algorithm)
    if algorithm == "fnv1a32" then
        return hash.fnv1a32(content)
    end
    if algorithm == "sha256" then
        return hash.sha256(content)
    end
    error({
        type = "InvalidManifestError",
        message = "Unsupported source hash algorithm: " .. tostring(algorithm),
        hash_algorithm = algorithm,
    })
end

local function readFile(file_path, opts)
    local normalized = normalizePath(file_path)
    local canonical = normalizePath(absolutePath(file_path))
    local expected_hashes = opts and opts.source_hashes
    local expected_hash = expected_hashes
        and (expected_hashes[file_path] or expected_hashes[normalized] or expected_hashes[canonical])
    if expected_hashes and expected_hash == nil then
        error({
            type = "InvalidManifestError",
            message = "Manifest is missing a source hash: " .. tostring(file_path),
            source_path = canonical,
        })
    end

    local content, read_err = fs.readRegularFile(file_path)
    if content == nil then
        if expected_hash ~= nil then
            error({
                type = "SourceChangedError",
                message = "Source changed during build: " .. tostring(file_path),
                source_path = canonical,
                expected_hash = expected_hash,
                actual_hash = nil,
                hash_algorithm = opts.source_hash_algorithm,
                cause = read_err,
            })
        end
        error({
            type = "ScriptNotFoundError",
            message = "Cannot read file: " .. tostring(file_path),
            path = file_path,
            cause = read_err,
        })
    end

    if expected_hash ~= nil then
        local actual_hash = contentHash(content, opts.source_hash_algorithm)
        if actual_hash ~= expected_hash then
            error({
                type = "SourceChangedError",
                message = "Source changed during build: " .. tostring(file_path),
                source_path = canonical,
                expected_hash = expected_hash,
                actual_hash = actual_hash,
                hash_algorithm = opts.source_hash_algorithm,
            })
        end
    end
    return content
end

local function quote(value)
    return string.format("%q", tostring(value or ""))
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function moduleAliases(configured, fallback, source_path)
    local aliases = {}
    local seen = {}
    local function add(alias)
        if type(alias) ~= "string" or alias == "" or alias:find("\0", 1, true) then
            error({
                type = "InvalidOptionsError",
                message = "Invalid generated module alias for " .. tostring(source_path),
                source_path = source_path,
                module_name = alias,
            })
        end
        if not seen[alias] then
            seen[alias] = true
            aliases[#aliases + 1] = alias
        end
    end

    if type(configured) == "string" then
        add(configured)
    elseif type(configured) == "table" then
        for key, value in pairs(configured) do
            if type(key) == "number" and type(value) == "string" then
                add(value)
            elseif value then
                add(key)
            end
        end
    elseif configured ~= nil then
        error({
            type = "InvalidOptionsError",
            message = "Generated module aliases must be a string or table",
            source_path = source_path,
        })
    else
        add(fallback)
    end

    if #aliases == 0 then
        add(fallback)
    end
    table.sort(aliases)
    return aliases
end

function M.moduleNameFromPath(file_path, entry)
    if entry and entry ~= "" then
        return path.moduleNameFromLuaPath(file_path, entry)
    end
    file_path = normalizePath(file_path)
    if file_path:match("/init%.lua$") then
        return file_path:match("([^/]+)/init%.lua$") or "init"
    end
    local name = basename(file_path)
    return (name:gsub("%.lua$", ""))
end

function M.buildPayload(opts)
    opts = opts or {}
    if not opts.entry then
        error({
            type = "InvalidOptionsError",
            message = "entry is required",
        })
    end

    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local payload = {
        entry = {
            id = "__entry__",
            path = opts.entry,
            source = readFile(opts.entry, opts),
        },
        modules = {},
        module_records = {},
    }

    local records_by_path = {}
    local alias_owners = {}
    for _, script_path in ipairs(dependencies.scripts or {}) do
        local normalized = normalizePath(script_path)
        local canonical = normalizePath(absolutePath(script_path))
        local record = records_by_path[canonical]
        if not record then
            record = {
                path = canonical,
                source = readFile(script_path, opts),
                index = #payload.module_records + 1,
            }
            records_by_path[canonical] = record
            payload.module_records[#payload.module_records + 1] = record
        end
        local configured = opts.module_names
            and (opts.module_names[script_path]
                or opts.module_names[normalized]
                or opts.module_names[canonical])
        local aliases = moduleAliases(
            configured,
            M.moduleNameFromPath(script_path, opts.entry),
            canonical
        )
        for _, module_name in ipairs(aliases) do
            local owner = alias_owners[module_name]
            if owner and owner ~= canonical then
                error({
                    type = "DuplicateModuleError",
                    message = "Duplicate generated module name: " .. module_name,
                    module_name = module_name,
                    first_source = owner,
                    second_source = canonical,
                })
            end
            alias_owners[module_name] = canonical
            payload.modules[module_name] = record
        end
    end

    return payload
end

local function emitPayload(payload)
    local lines = {}
    lines[#lines + 1] = "local module_records = {"
    for index, record in ipairs(payload.module_records or {}) do
        lines[#lines + 1] = "  [" .. tostring(index) .. "] = {"
        lines[#lines + 1] = "    path = " .. quote(record.path) .. ","
        lines[#lines + 1] = "    source = " .. quote(record.source) .. ","
        lines[#lines + 1] = "  },"
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "local payload = {"
    lines[#lines + 1] = "  entry = {"
    lines[#lines + 1] = "    id = " .. quote(payload.entry.id) .. ","
    lines[#lines + 1] = "    path = " .. quote(payload.entry.path) .. ","
    lines[#lines + 1] = "    source = " .. quote(payload.entry.source) .. ","
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "  modules = {"
    for _, name in ipairs(sortedKeys(payload.modules or {})) do
        local record = payload.modules[name]
        lines[#lines + 1] = "    [" .. quote(name) .. "] = module_records["
            .. tostring(record.index) .. "],"
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

-- RUNTIME_SOURCE is embedded into the C launcher bootstrap.
-- Functionally similar to src/runtime.lua (Lua API / tests) but maintained
-- independently. When changing bootstrap behavior, check both files.
local RUNTIME_SOURCE = [=[
local function pathDirname(path)
  path = tostring(path or ""):gsub("\\", "/")
  return path:match("^(.*)/[^/]+$") or "."
end

local function joinPath(left, right)
  left = tostring(left or "")
  right = tostring(right or "")
  if right:sub(1, 1) == "/" or right:match("^%a:/") then return right end
  if left == "" or left == "." then return right end
  return left:gsub("/+$", "") .. "/" .. right
end

local function configureNativePath(native_dir, launcher_path)
  if not native_dir or native_dir == "" then return end
  local resolved = joinPath(pathDirname(launcher_path), native_dir)
  local patterns = table.concat({
    resolved .. "/?.so",
    resolved .. "/?/init.so",
    resolved .. "/?.dylib",
    resolved .. "/?/init.dylib",
    resolved .. "/?.dll",
    resolved .. "/?/init.dll",
  }, ";")
  package.cpath = patterns .. ";" .. package.cpath
end

local function stripSource(source)
  source = tostring(source or "")
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  if source:sub(1, 2) == "#!" then
    local newline_start, newline_end = source:find("\r\n", 1, true)
    if not newline_start then newline_start, newline_end = source:find("[\r\n]") end
    if newline_start then source = "\n" .. source:sub(newline_end + 1) else source = "" end
  end
  return source
end

local function loaderTable()
  return package.searchers or package.loaders
end

local unpackValues = table.unpack or unpack

local function packValues(...)
  return { n = select("#", ...), ... }
end

local function loadText(source, chunk_name)
  if type(source) ~= "string" then return nil, "source must be a string" end
  if source:byte(1) == 27 then return nil, "binary chunks are not accepted" end
  if _VERSION == "Lua 5.1" then return loadstring(source, chunk_name) end
  return load(source, chunk_name, "t")
end

local function loadPayloadSource(record, chunk_name)
  local loader, err = loadText(stripSource(record.source or ""), chunk_name or ("@" .. tostring(record.path or "bundle")))
  if not loader then error(err) end
  return loader
end

local function restoreLoadedModules(loaded, previous_modules)
  for name, previous in pairs(previous_modules) do
    if previous.present then rawset(loaded, name, previous.value)
    else rawset(loaded, name, nil) end
  end
end

local function install(payload)
  local modules = payload.modules or {}
  local searchers = loaderTable()
  local searcher
  searcher = function(module_name)
    local record = modules[module_name]
    if not record then return "\n\tno bundled module '" .. tostring(module_name) .. "'" end
    return loadPayloadSource(record, "@" .. tostring(record.path or module_name)), record.path
  end
  table.insert(searchers, 2, searcher)
  return function()
    for i = #searchers, 1, -1 do
      if searchers[i] == searcher then table.remove(searchers, i); break end
    end
  end
end

local function run(payload, run_args)
  local loaded = package.loaded
  local previous_modules = {}
  for name in pairs(payload.modules or {}) do
    local value = rawget(loaded, name)
    previous_modules[name] = { present = value ~= nil, value = value }
    rawset(loaded, name, nil)
  end
  local install_ok, uninstall = pcall(install, payload)
  if not install_ok then
    restoreLoadedModules(loaded, previous_modules)
    error(uninstall, 0)
  end
  local old_arg = _G.arg
  local entry = payload.entry
  local runtime_arg = { [0] = entry.path or entry.id or "__entry__" }
  for i = 1, #(run_args or {}) do runtime_arg[i] = run_args[i] end
  _G.arg = runtime_arg
  local results = packValues(pcall(function()
    return loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))()
  end))
  _G.arg = old_arg
  local uninstall_ok, uninstall_err = pcall(uninstall)
  restoreLoadedModules(loaded, previous_modules)
  if not results[1] then error(results[2], 0) end
  if not uninstall_ok then error(uninstall_err, 0) end
  return unpackValues(results, 2, results.n)
end
]=]

function M.generateBootstrap(opts)
    local payload = M.buildPayload(opts)
    local source = {}
    source[#source + 1] = "-- luainstaller generated bootstrap"
    source[#source + 1] = emitPayload(payload)
    source[#source + 1] = RUNTIME_SOURCE
    source[#source + 1] = "local launcher_path = arg and arg[0] or \"\""
    source[#source + 1] = "configureNativePath(" .. quote(opts.native_dir or "") .. ", launcher_path)"
    source[#source + 1] = "local run_args = {}"
    source[#source + 1] = "if arg then for i = 1, #arg do run_args[i] = arg[i] end end"
    source[#source + 1] = "return run(payload, run_args)"
    return table.concat(source, "\n")
end

return M
