--[[
Linux onedir bundler for luainstaller.

Author:
    WaterRun
File:
    bundler.lua
Date:
    2026-06-21
Updated:
    2026-06-21
]]

local launcher = require("luainstaller.launcher")

local M = {}

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"

local function makeError(err_type, message, details)
    local err = {
        type = err_type,
        message = message,
    }
    if details then
        for k, v in pairs(details) do
            err[k] = v
        end
    end
    return {
        ok = false,
        error = err,
    }
end

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

local function currentDirectory()
    local pipe = io.popen(IS_WINDOWS and "cd" or "pwd")
    if pipe then
        local dir = pipe:read("*l")
        pipe:close()
        if dir and dir ~= "" then
            return normalizePath(dir)
        end
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

local function dirname(path)
    path = normalizePath(path)
    return path:match("^(.+)/[^/]+$") or "."
end

local function basename(path)
    path = normalizePath(path)
    return path:match("[^/]+$") or path
end

local function stem(path)
    local name = basename(path)
    return name:match("^(.+)%.[^%.]+$") or name
end

local function shellQuote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function commandOutput(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a") or ""
    local ok = pipe:close()
    if ok == true or ok == 0 then
        return true, output
    end
    return false, output
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

local function writeFile(path, content)
    local file = io.open(path, "wb")
    if not file then
        return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
            path = path,
        })
    end
    file:write(content or "")
    file:close()
    return nil
end

local function copyFile(source, destination)
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

local function executableName(out_path, entry)
    local name = basename(out_path or "")
    if name == "" or name == "." then
        name = stem(entry)
    end
    if IS_WINDOWS and not name:match("%.exe$") then
        name = name .. ".exe"
    end
    return name
end

local function defaultOut(entry)
    return normalizePath("build/" .. stem(entry))
end

local function unsafeOutputError(path)
    return makeError("InvalidOutputError", "Refusing to overwrite unsafe output directory: " .. tostring(path), {
        path = path,
    })
end

local function validateOutputDirectory(path)
    local normalized = normalizePath(path)
    if normalized == "/" or normalized == "." or normalized == "" then
        return unsafeOutputError(path)
    end
    if normalized == currentDirectory() then
        return unsafeOutputError(path)
    end
    return nil
end

local function traceModuleMaps(trace)
    local lua_names = {}
    local native_names = {}
    for _, item in ipairs(trace or {}) do
        if item.selected_path and item.requested then
            if item.classification == "lua" or item.selected_type == "lua" then
                lua_names[normalizePath(item.selected_path)] = item.requested
            elseif item.classification == "native" or item.selected_type == "native" then
                native_names[normalizePath(item.selected_path)] = item.requested
            end
        end
    end
    return lua_names, native_names
end

local function nativeDestinations(native_path, module_name, native_dir)
    local destinations = {}
    local seen = {}
    local function add(path)
        path = normalizePath(path)
        if not seen[path] then
            seen[path] = true
            destinations[#destinations + 1] = path
        end
    end

    add(native_dir .. "/" .. basename(native_path))
    if module_name and module_name ~= "" then
        local ext = basename(native_path):match("(%.[^%.]+)$") or ".so"
        add(native_dir .. "/" .. module_name:gsub("%.", "/") .. ext)
    end
    return destinations
end

function M.bundleOnedir(opts)
    opts = opts or {}
    if IS_WINDOWS then
        return makeError("UnsupportedPlatformError", "onedir bundling is implemented for Linux in this stage")
    end

    local manifest = opts.manifest
    local dependencies = opts.dependencies or { scripts = {}, libraries = {} }
    local entry = opts.entry
    if type(manifest) ~= "table" then
        return makeError("InvalidOptionsError", "manifest is required")
    end
    if type(entry) ~= "string" or entry == "" then
        return makeError("InvalidOptionsError", "entry is required")
    end

    local out_dir = absolutePath(opts.out or defaultOut(entry))
    local output_err = validateOutputDirectory(out_dir)
    if output_err then
        return output_err
    end

    local exe_name = executableName(out_dir, entry)
    local exe_path = normalizePath(out_dir .. "/" .. exe_name)
    local luai_dir = normalizePath(out_dir .. "/.luai")
    local native_dir = normalizePath(luai_dir .. "/native")
    local build_dir = normalizePath(luai_dir .. "/build")
    local c_path = normalizePath(build_dir .. "/launcher.c")

    local err = removeTree(out_dir) or ensureDirectory(native_dir) or ensureDirectory(build_dir)
    if err then
        return err
    end

    local lua_names, native_names = traceModuleMaps(opts.trace or manifest.trace or {})
    local c_source
    local ok_generate, generated = pcall(launcher.generateSource, {
        entry = entry,
        dependencies = dependencies,
        module_names = lua_names,
        native_dir = ".luai/native",
    })
    if not ok_generate then
        return makeError("LauncherGenerationError", tostring(generated))
    end
    c_source = generated

    err = writeFile(c_path, c_source)
    if err then
        return err
    end

    for _, path in ipairs(dependencies.libraries or {}) do
        local normalized = normalizePath(path)
        for _, destination in ipairs(nativeDestinations(normalized, native_names[normalized], native_dir)) do
            err = copyFile(normalized, destination)
            if err then
                return err
            end
        end
    end

    local pkg_ok, pkg_flags = commandOutput("pkg-config --cflags --libs lua")
    if not pkg_ok then
        return makeError("ToolchainError", "pkg-config cannot find lua", {
            output = pkg_flags,
        })
    end

    local cleaned_pkg_flags = (pkg_flags:gsub("%s+$", ""))
    local compile_cmd = table.concat({
        "cc",
        shellQuote(c_path),
        "-o",
        shellQuote(exe_path),
        "-Wl,-rpath," .. shellQuote("$ORIGIN/.luai/native"),
        cleaned_pkg_flags,
    }, " ")
    local compile_ok, compile_output = commandOutput(compile_cmd)
    if not compile_ok then
        return makeError("CompilationFailedError", "C launcher compilation failed", {
            command = compile_cmd,
            output = compile_output,
        })
    end

    commandOutput("chmod +x " .. shellQuote(exe_path))

    local runtime_record
    err, runtime_record = copyLuaRuntime(exe_path, native_dir)
    if err then
        return err
    end
    manifest.launcher.lua_runtime = runtime_record

    err = writeFile(normalizePath(luai_dir .. "/manifest.lua"), serializeManifest(manifest))
    if err then
        return err
    end

    return {
        ok = true,
        action = "bundle",
        mode = "onedir",
        entry = entry,
        out = out_dir,
        executable = exe_path,
        manifest = manifest,
    }
end

return M
