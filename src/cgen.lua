--[[
Lua bootstrap generation for luainstaller bundles.

Author:
    WaterRun
File:
    cgen.lua
Date:
    2026-06-16
Updated:
    2026-06-16
]]

local M = {}

local function normalizePath(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function basename(path)
    path = normalizePath(path)
    return path:match("[^/]+$") or path
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        error({
            type = "ScriptNotFoundError",
            message = "Cannot read file: " .. tostring(path),
            path = path,
        })
    end
    local content = handle:read("*a")
    handle:close()
    return content or ""
end

local function quote(value)
    return string.format("%q", tostring(value or ""))
end

function M.moduleNameFromPath(path)
    path = normalizePath(path)
    if path:match("/init%.lua$") then
        return path:match("([^/]+)/init%.lua$") or "init"
    end
    local name = basename(path)
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
            source = readFile(opts.entry),
        },
        modules = {},
    }

    for _, path in ipairs(dependencies.scripts or {}) do
        local module_name = opts.module_names and opts.module_names[path] or M.moduleNameFromPath(path)
        if payload.modules[module_name] then
            error({
                type = "DuplicateModuleError",
                message = "Duplicate generated module name: " .. module_name,
                module_name = module_name,
            })
        end
        payload.modules[module_name] = {
            path = path,
            source = readFile(path),
        }
    end

    return payload
end

local function emitPayload(payload)
    local lines = {}
    lines[#lines + 1] = "local payload = {"
    lines[#lines + 1] = "  entry = {"
    lines[#lines + 1] = "    id = " .. quote(payload.entry.id) .. ","
    lines[#lines + 1] = "    path = " .. quote(payload.entry.path) .. ","
    lines[#lines + 1] = "    source = " .. quote(payload.entry.source) .. ","
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "  modules = {"
    for name, record in pairs(payload.modules or {}) do
        lines[#lines + 1] = "    [" .. quote(name) .. "] = {"
        lines[#lines + 1] = "      path = " .. quote(record.path) .. ","
        lines[#lines + 1] = "      source = " .. quote(record.source) .. ","
        lines[#lines + 1] = "    },"
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

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
    local rest = source:match("^[^\n]*(\n?.*)$")
    source = rest or ""
    if source:sub(1, 1) == "\n" then source = source:sub(2) end
  end
  return source
end

local function loaderTable()
  return package.searchers or package.loaders
end

local function loadPayloadSource(record, chunk_name)
  local loader, err = load(stripSource(record.source or ""), chunk_name or ("@" .. tostring(record.path or "bundle")), "t")
  if not loader then error(err) end
  return loader
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
  local uninstall = install(payload)
  local old_arg = _G.arg
  local entry = payload.entry
  local runtime_arg = { [0] = entry.path or entry.id or "__entry__" }
  for i = 1, #(run_args or {}) do runtime_arg[i] = run_args[i] end
  _G.arg = runtime_arg
  local ok, result = pcall(function()
    return loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))()
  end)
  _G.arg = old_arg
  uninstall()
  if not ok then error(result) end
  return result
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
