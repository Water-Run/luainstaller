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
    2026-07-10
]]

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
        local rest = source:match("^[^\n]*(\n?.*)$")
        source = rest or ""
        if source:sub(1, 1) == "\n" then
            source = source:sub(2)
        end
    end
    return source
end

local function loadPayloadSource(record, chunk_name)
    local source = M.stripSource(record.source or "")
    local loader, err = load(source, chunk_name or ("@" .. tostring(record.path or "bundle")), "t")
    if not loader then
        error({
            type = "LoadError",
            message = tostring(err),
            path = record.path,
        })
    end
    return loader
end

function M.install(payload)
    payload = payload or {}
    local modules = payload.modules or {}
    local searchers = loaderTable()
    local searcher

    searcher = function(module_name)
        local record = modules[module_name]
        if not record then
            return "\n\tno bundled module '" .. tostring(module_name) .. "'"
        end
        return loadPayloadSource(record, "@" .. tostring(record.path or module_name)), record.path
    end

    table.insert(searchers, 2, searcher)

    return function()
        for i = #searchers, 1, -1 do
            if searchers[i] == searcher then
                table.remove(searchers, i)
                break
            end
        end
    end
end

function M.run(payload, run_args)
    payload = payload or {}
    run_args = run_args or {}
    local entry = payload.entry
    if type(entry) ~= "table" or type(entry.source) ~= "string" then
        error({
            type = "InvalidPayloadError",
            message = "payload.entry.source is required",
        })
    end

    local uninstall = M.install(payload)
    local old_arg = _G.arg
    local runtime_arg = { [0] = entry.path or entry.id or "__entry__" }
    for i = 1, #run_args do
        runtime_arg[i] = run_args[i]
    end
    _G.arg = runtime_arg

    local ok, result = pcall(function()
        local entry_loader = loadPayloadSource(entry, "@" .. tostring(entry.path or entry.id or "__entry__"))
        return entry_loader()
    end)

    _G.arg = old_arg
    uninstall()

    if not ok then
        error(result)
    end
    return result
end

return M
