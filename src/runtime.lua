--[[
Pure Lua bundle runtime for luainstaller.

Used by Lua API tests and in-process runs. Generated bundles embed the
bootstrap from src/cgen.lua RUNTIME_SOURCE instead. Keep the two in sync
when changing searcher install or source loading behavior.

Author:
    WaterRun
File:
    runtime.lua
Date:
    2026-06-16
Updated:
    2026-10-15
]]

local compat = require("luainstaller.compat")

local M = {}

local function loaderTable()
    return package.searchers or package.loaders
end

function M.stripSource(source)
    source = tostring(source or "")
    if source:sub(1, 3) == "\239\187\191" then
        source = source:sub(4)
    end
    if source:sub(1, 2) == "#!" then
        local newline_start, newline_end = source:find("[\r\n]")
        if newline_start then
            local pair = source:sub(newline_end, newline_end + 1)
            if pair == "\r\n" or pair == "\n\r" then newline_end = newline_end + 1 end
            source = "\n" .. source:sub(newline_end + 1)
        else
            source = ""
        end
    end
    return source
end

local function loadPayloadSource(record, chunk_name)
    local source = M.stripSource(record.source or "")
    local loader, err = compat.loadText(
        source,
        chunk_name or ("@" .. tostring(record.path or "bundle"))
    )
    if not loader then
        error({
            type = "LoadError",
            message = tostring(err),
            path = record.path,
        })
    end
    return loader
end

local function loadNativeModule(record, module_name, native_root)
    local root = tostring(native_root or ".")
    local filename = record.path
    if filename:sub(1, 1) ~= "/" and not filename:match("^%a:/")
        and root ~= "" and root ~= "." then
        filename = root:gsub("/+$", "") .. "/" .. filename
    end
    local symbol = module_name:gsub("%.", "_")
    local before, after = symbol:match("^(.-)%-(.*)$")
    local loader, err, stage
    if before and _VERSION ~= "Lua 5.1" then
        loader, err, stage = package.loadlib(filename, "luaopen_" .. before)
        if loader then return loader, filename end
        if stage ~= "init" then error(err, 0) end
    end
    loader, err = package.loadlib(filename, "luaopen_" .. (after or symbol))
    if not loader then
        error("error loading bundled module '" .. module_name .. "' from file '"
            .. filename .. "':\n\t" .. tostring(err), 0)
    end
    return loader, filename
end

local function restoreLoadedModules(loaded, previous_modules)
    for name, previous in pairs(previous_modules) do
        if previous.present then
            rawset(loaded, name, previous.value)
        else
            rawset(loaded, name, nil)
        end
    end
end

function M.install(payload)
    payload = payload or {}
    local modules = payload.modules or {}
    local native_modules = payload.native_modules or {}
    local searchers = loaderTable()
    local searcher
    local ffi, original_ffi_load
    if next(payload.ffi_libraries or {}) then
        ffi = require("ffi")
        original_ffi_load = ffi.load
    end

    searcher = function(module_name)
        local native = native_modules[module_name]
        if native then
            return loadNativeModule(native, module_name, payload.native_root)
        end
        local record = modules[module_name]
        if not record then
            return "\n\tno bundled module '" .. tostring(module_name) .. "'"
        end
        return loadPayloadSource(record, "@" .. tostring(record.path or module_name)), record.path
    end

    table.insert(searchers, 2, searcher)
    if ffi then
        ffi.load = function(name, ...)
            local record = payload.ffi_libraries[name]
            local filename = record and ((payload.native_root or "."):gsub("/+$", "")
                .. "/" .. record.path) or name
            return original_ffi_load(filename, ...)
        end
    end

    return function()
        if ffi then ffi.load = original_ffi_load end
        for i = #searchers, 1, -1 do
            if searchers[i] == searcher then
                table.remove(searchers, i)
                break
            end
        end
    end
end

function M.run(payload, run_args, application_arg0)
    payload = payload or {}
    run_args = run_args or {}
    local entry = payload.entry
    if type(entry) ~= "table" or type(entry.source) ~= "string" then
        error({
            type = "InvalidPayloadError",
            message = "payload.entry.source is required",
        })
    end

    local loaded = package.loaded
    local previous_modules = {}
    for name in pairs(payload.modules or {}) do
        local value = rawget(loaded, name)
        previous_modules[name] = {
            present = value ~= nil,
            value = value,
        }
        rawset(loaded, name, nil)
    end
    for name in pairs(payload.native_modules or {}) do
        local value = rawget(loaded, name)
        previous_modules[name] = {
            present = value ~= nil,
            value = value,
        }
        rawset(loaded, name, nil)
    end

    local install_ok, install_result = pcall(M.install, payload)
    if not install_ok then
        restoreLoadedModules(loaded, previous_modules)
        error(install_result, 0)
    end
    local uninstall = install_result
    local old_arg = _G.arg
    local runtime_arg = { [0] = application_arg0
        or (type(old_arg) == "table" and old_arg[0])
        or entry.path or entry.id or "__entry__" }
    for i = 1, #run_args do
        runtime_arg[i] = run_args[i]
    end
    _G.arg = runtime_arg

    local results = compat.pack(pcall(function()
        local entry_loader = loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))
        return entry_loader()
    end))

    _G.arg = old_arg
    local uninstall_ok, uninstall_err = pcall(uninstall)
    restoreLoadedModules(loaded, previous_modules)

    if not results[1] then
        error(results[2], 0)
    end
    if not uninstall_ok then
        error(uninstall_err, 0)
    end
    return compat.unpack(results, 2, results.n)
end

return M
