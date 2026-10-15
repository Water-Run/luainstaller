--[[
Preprocess MoonScript through the device's compiler into a private Lua tree.

Author:
    WaterRun
File:
    moon.lua
Date:
    2026-10-13
Updated:
    2026-10-15
]]

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local hash = require("luainstaller.hash")
local result = require("luainstaller.result")
local M = {}
local WINDOWS = package.config:sub(1, 1) == "\\"

local function failure(kind, message, fields)
    local error_value = fields or {}
    error_value.type, error_value.message = kind, message
    return {ok=false, error=error_value}
end

function M.fromThrown(value, default_type)
    if type(value) == "table" and value.ok == false and type(value.error) == "table" then return value end
    if type(value) == "table" and value.type then return result.fromThrown(value, default_type) end
    local message = type(value) == "table" and value.message or tostring(value)
    local lowered = type(message) == "string" and message:lower() or ""
    if lowered == "interrupted" or lowered:find("interrupted!", 1, true) then
        return failure("InterruptedError", "MoonScript operation interrupted", {cause=message})
    end
    if default_type then return result.fromThrown(value, default_type) end
    return failure("MoonScriptCompilationError", "MoonScript preprocessing failed", {cause=tostring(value)})
end

local function isMoon(filename)
    return filename:lower():match("%.moon$") ~= nil
end

local function excluded(filename, excludes)
    filename = path.normalize(filename)
    for _, value in ipairs(excludes or {}) do
        value = path.normalize(value)
        if filename == value or path.basename(filename) == value
            or filename:sub(-#value - 1) == "/" .. value then return true end
    end
    return false
end

function M.findCompiler()
    if WINDOWS then
        local host = require("luainstaller.windows_host")
        for _, name in ipairs({"moonc.exe", "moonc.bat", "moonc.cmd", "moonc"}) do
            local found, filename = host.call("which", name, process.environmentVariable("PATH") or "")
            if found and filename ~= "" then return filename end
        end
    else
        local found, filename = process.output("command -v moonc")
        filename = tostring(filename or ""):match("^%s*(.-)%s*$")
        if found and filename ~= "" and not filename:find("[%c]") then
            return path.absolute(filename)
        end
    end
    return nil, failure("MoonScriptCompilerNotFoundError",
        "MoonScript input requires the local moonc command. Install MoonScript (luarocks install moonscript), "
        .. "then retry the same command; use --no-moon-detect or luai -M to treat the input as Lua.")
end

local function compile(compiler, input, directory, limit)
    if WINDOWS and compiler:lower():match("%.[bc][am][td]$") then
        local shell = process.environmentVariable("ComSpec") or process.environmentVariable("COMSPEC") or "cmd.exe"
        return process.outputCommand(shell, {"/d", "/v:off", "/s", "/c",
            '"%LUAI_MOON_COMPILER%" -p "%LUAI_MOON_INPUT%"'}, {
            LUAI_MOON_COMPILER=compiler, LUAI_MOON_INPUT=input,
        }, {working_directory=directory, max_output_bytes=limit})
    end
    return process.outputCommand(compiler, {"-p", input}, {}, {
        working_directory=directory, max_output_bytes=limit,
    })
end

function M.prepare(opts)
    local original_entry = path.absolute(opts.entry)
    local input, input_error, state = fs.readRegularFile(original_entry, opts.max_source_bytes)
    if input == nil then
        if state and state.limit_exceeded then
            return nil, result.resourceLimit("source-bytes", opts.max_source_bytes, original_entry)
        end
        return nil, failure("ScriptNotFoundError", "MoonScript input not found: " .. original_entry,
            {script_path=original_entry, cause=input_error})
    end
    local compiler, compiler_error = M.findCompiler()
    if not compiler then return nil, compiler_error end
    local workspace, workspace_error = fs.makePrivateDirectory("moon-work")
    if not workspace then return nil, failure("FilesystemError", "Cannot create MoonScript workspace", {cause=workspace_error}) end
    local source_root = path.dirname(original_entry)
    local lua_root, compiler_root = path.join(workspace, "source"), path.join(workspace, "compiler")
    local context = {workspace=workspace, records={}, mapping={}, originals={}, materials={},
        prepared_paths={}, folded_mapping={}}
    function context.preparedPath(filename)
        filename = path.absolute(filename)
        return context.prepared_paths[WINDOWS and filename:lower() or filename] or filename
    end
    function context.cleanup()
        return fs.removeTree(workspace)
    end
    function context.verify()
        for _, record in ipairs(context.records) do
            if fs.pathType(record.original) ~= "file" then
                return failure("SourceChangedError", "Source changed during MoonScript preprocessing",
                    {source_path=record.original})
            end
            local digest = hash.sha256File(record.original, record.limit)
            if digest ~= record.original_hash then
                return failure("SourceChangedError", "Source changed during MoonScript preprocessing",
                    {source_path=record.original, expected_hash=record.original_hash, actual_hash=digest})
            end
        end
        return {ok=true}
    end
    local called, value = xpcall(function()
        assert(fs.makeDirectory(lua_root))
        assert(fs.makeDirectory(compiler_root))
        assert(fs.makeDirectory(path.join(workspace, "inputs")))
        local items, tree_error = fs.listTree(source_root)
        if not items then return failure("FilesystemError", "Cannot scan MoonScript project", {cause=tree_error}) end
        local candidates, seen_original, destinations = {}, {}, {}
        local folded_originals, original_aliases = {}, {}
        local explicit_inputs, deferred = {}, {}
        for _, filename in ipairs(opts.include) do
            local original = path.absolute(filename)
            explicit_inputs[WINDOWS and original:lower() or original] = true
        end
        local runtime = opts.depscan ~= false and opts.discovery_mode == "runtime"
        local manual = opts.depscan == false or opts.discovery_mode == "manual"
        local function add(original, relative, external)
            original = path.absolute(original)
            if seen_original[original] then return end
            if WINDOWS and folded_originals[original:lower()] then
                local previous = folded_originals[original:lower()]
                local same, identity_error = fs.sameFile(previous, original)
                if same == nil then
                    error(failure("FilesystemError", "Cannot inspect MoonScript source identity",
                        {source_path=original, cause=identity_error}), 0)
                end
                if same then original_aliases[original] = previous; return end
            end
            local destination_name = isMoon(original) and relative:gsub("%.[mM][oO][oO][nN]$", ".lua") or relative
            local destination = path.join(external and path.join(workspace, "external") or lua_root, destination_name)
            local key = WINDOWS and destination:lower() or destination
            local is_deferred = isMoon(original) and original ~= original_entry and not runtime
                and excluded(original, opts.exclude)
                and not explicit_inputs[WINDOWS and original:lower() or original]
            if not is_deferred and destinations[key] then
                error(failure("MoonScriptCollisionError", "MoonScript and Lua inputs would overwrite the same compiled file",
                    {source_path=original, conflicting_path=destinations[key]}), 0)
            end
            if not is_deferred then destinations[key] = original end
            seen_original[original] = true
            if WINDOWS then folded_originals[original:lower()] = folded_originals[original:lower()] or original end
            local candidate = {original=original, prepared=destination, relative=relative,
                deferred=is_deferred}
            candidates[#candidates + 1] = candidate
            candidate.index = #candidates
            if candidate.deferred then
                candidate.conflicting_path = deferred[key] and deferred[key].original
                deferred[key] = candidate
            end
        end
        add(original_entry, path.basename(original_entry))
        for _, item in ipairs(items) do
            local original = path.join(source_root, item.path)
            local lower = item.path:lower()
            local skipped = item.path:match("^%.git/") or item.path:match("^%.worktrees/")
                or item.path:find("/.luai/", 1, true) or item.path:match("^%.luai/")
                or path.isWithin(original, workspace)
                or (opts.out and path.isWithin(original, path.absolute(opts.out)))
                or (manual and not explicit_inputs[WINDOWS and original:lower() or original])
            if not skipped and original ~= original_entry and item.type == "file"
                and (lower:match("%.lua$") or lower:match("%.moon$") or lower:match("%.so[%.%d]*$")
                    or lower:match("%.dll$") or lower:match("%.dylib$")) then
                add(original, item.path)
            elseif not skipped and item.type == "reparse" and (lower:match("%.moon$") or lower:match("%.lua$")) then
                return failure("FilesystemError", "MoonScript preprocessing refuses linked source files", {source_path=original})
            end
        end
        for _, filename in ipairs(opts.include) do
            local original = path.absolute(filename)
            if not seen_original[original] and isMoon(original) then
                add(original, hash.sha256(original):sub(1, 16) .. "/" .. path.basename(original), true)
            end
        end
        local total = 0
        if #candidates > 10000 then
            return result.resourceLimit("preprocessed-files", 10000, original_entry, #candidates)
        end
        local function prepare_candidate(candidate)
            candidate.limit = (isMoon(candidate.original) or candidate.original:lower():match("%.lua$"))
                and opts.max_source_bytes or opts.max_bundle_bytes
            local content, read_error, read_state
            if candidate.original == original_entry then
                content = input
            else
                content, read_error, read_state = fs.readRegularFile(candidate.original, candidate.limit)
            end
            if content == nil then
                if read_state and read_state.limit_exceeded then
                    return result.resourceLimit("source-bytes", opts.max_source_bytes, candidate.original)
                end
                return failure("FilesystemError", "Cannot read preprocessing source", {source_path=candidate.original, cause=read_error})
            end
            candidate.original_hash = hash.sha256(content)
            if isMoon(candidate.original) then
                local snapshot = path.join(workspace, "inputs/source-" .. candidate.index .. ".moon")
                assert(fs.writeFile(snapshot, content))
                local material_name = candidate.relative
                if not path.isWithin(candidate.original, source_root) then
                    material_name = "external/" .. candidate.original_hash .. "/" .. path.basename(candidate.original)
                end
                context.materials[#context.materials + 1] = {source_path=snapshot,
                    destination=".luai/build/moon_sources/" .. material_name, content_hash=candidate.original_hash,
                    prepared_path=candidate.prepared}
                local compiled, output, status = compile(compiler, snapshot, compiler_root, opts.max_source_bytes)
                if not compiled then
                    if status and status.reason == "output-limit" then
                        return result.resourceLimit("compiled-source-bytes", opts.max_source_bytes, candidate.original)
                    end
                    local start = tostring(output):find(snapshot, 1, true)
                    if start then output = output:sub(1, start - 1) .. candidate.original .. output:sub(start + #snapshot) end
                    return failure("MoonScriptCompilationError", "MoonScript compilation failed: " .. candidate.original,
                        {script_path=candidate.original, output=output, command_status=status})
                end
                total = total + #content
                content = output
            end
            total = total + #content
            if total > opts.max_bundle_bytes then
                return result.resourceLimit("preprocessed-bytes", opts.max_bundle_bytes, original_entry, total)
            end
            assert(fs.makeDirectory(path.dirname(candidate.prepared)))
            assert(fs.writeFile(candidate.prepared, content))
            context.records[#context.records + 1] = candidate
            context.mapping[candidate.prepared] = candidate.original
            context.prepared_paths[WINDOWS and candidate.prepared:lower() or candidate.prepared] = candidate.prepared
            if WINDOWS then context.folded_mapping[candidate.prepared:lower()] = candidate.original end
            context.originals[candidate.original] = candidate.original_hash
            return {ok=true}
        end
        for _, candidate in ipairs(candidates) do
            if not candidate.deferred then
                local prepared = prepare_candidate(candidate)
                if not prepared.ok then return prepared end
            end
        end
        if not runtime and not manual and next(deferred) then
            -- Exclusion filters the final dependency list. Required excluded
            -- modules still participate in ordinary static discovery; compile
            -- those lazily and leave unrelated excluded sources untouched.
            local analyzer = require("luainstaller.analyzer")
            local resolver = analyzer.ModuleResolver.new(lua_root)
            local queue = {candidates[1].prepared}
            local queued = {[queue[1]]=true}
            local position = 1
            while position <= #queue do
                if position > 10000 then
                    return result.resourceLimit("preprocessed-discovery-files", 10000, original_entry, position)
                end
                local filename = queue[position]
                position = position + 1
                local content = fs.readRegularFile(filename, opts.max_source_bytes)
                local parsed, requires = pcall(function()
                    return analyzer.LuaLexer.new(content, filename):extractRequires()
                end)
                if parsed then
                    for _, request in ipairs(requires) do
                        for _, candidate in ipairs(resolver:buildCandidates(request.name, filename)) do
                            local resolved = path.absolute(candidate.path)
                            local key = WINDOWS and resolved:lower() or resolved
                            if deferred[key] and fs.pathType(resolved) ~= "file" then
                                if deferred[key].conflicting_path then
                                    return failure("MoonScriptCollisionError", "Excluded MoonScript inputs have the same compiled file",
                                        {source_path=deferred[key].original, conflicting_path=deferred[key].conflicting_path})
                                end
                                local prepared = prepare_candidate(deferred[key])
                                if not prepared.ok then return prepared end
                                deferred[key] = nil
                            end
                            if fs.pathType(resolved) == "file" then
                                if candidate.type == "lua" and not queued[resolved] then
                                    queue[#queue + 1], queued[resolved] = resolved, true
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
        local normalized = {}
        for key, item in pairs(opts) do normalized[key] = item end
        normalized.entry = path.join(lua_root, path.basename(original_entry):gsub("%.[mM][oO][oO][nN]$", ".lua"))
        normalized.moon_detect = false
        normalized.include, normalized.exclude = {}, {}
        for _, filename in ipairs(opts.include) do
            local requested = path.absolute(filename)
            local original = requested
            original = original_aliases[original] or original
            local mapped
            for prepared, source in pairs(context.mapping) do if source == original then mapped = prepared end end
            if WINDOWS and mapped and requested ~= original then
                local relative = path.relativeWithin(requested, source_root)
                local alias = relative and path.join(lua_root, relative)
                    or path.join(path.dirname(mapped), path.basename(requested))
                alias = alias:gsub("%.[mM][oO][oO][nN]$", ".lua")
                context.mapping[alias] = requested
                context.originals[requested] = context.originals[original]
                mapped = alias
            end
            normalized.include[#normalized.include + 1] = mapped or original
        end
        for _, filename in ipairs(opts.exclude) do
            for prepared, source in pairs(context.mapping) do
                if excluded(source, {filename}) then normalized.exclude[#normalized.exclude + 1] = prepared end
            end
            normalized.exclude[#normalized.exclude + 1] = filename
        end
        context.options = normalized
        local verified = context.verify()
        if not verified.ok then return verified end
        return {ok=true}
    end, function(error_value) return error_value end)
    if not called or not value.ok then
        local cleanup_called, cleaned, cleanup_error = pcall(context.cleanup)
        if not cleanup_called then cleanup_error, cleaned = cleaned, false end
        local error_result = called and value or M.fromThrown(value)
        if not cleaned then error_result.error.cleanup_error = cleanup_error; error_result.error.cleanup_path = workspace end
        return nil, error_result
    end
    return context
end

function M.remap(value, context, seen)
    if type(value) == "string" then
        if context.mapping[value] then return context.mapping[value] end
        local searched = WINDOWS and value:lower() or value
        if WINDOWS and context.folded_mapping and context.folded_mapping[searched] then
            return context.folded_mapping[searched]
        end
        for prepared, original in pairs(context.mapping) do
            local start = searched:find(WINDOWS and prepared:lower() or prepared, 1, true)
            if start then
                value = value:sub(1, start - 1) .. original .. value:sub(start + #prepared)
                searched = WINDOWS and value:lower() or value
            end
        end
        return value
    end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local mapped = {}; seen[value] = mapped
    for key, item in pairs(value) do mapped[M.remap(key, context, seen)] = M.remap(item, context, seen) end
    return mapped
end

return M
