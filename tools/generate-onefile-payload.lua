--[[
Regenerate payload.inc for an extracted luainstaller onefile bundle.

Usage:
    lua generate-onefile-payload.lua <extracted-root> [output]

The generated payload-files.lua is authoritative for path ordering and mode.
]]

local root = assert(arg and arg[1], "extracted bundle root is required")
local separator = package.config:sub(1, 1)
local windows = separator == "\\"

local function normalize(value)
    value = tostring(value or ""):gsub("\\", "/")
    local prefix = value:sub(1, 1) == "/" and "/" or ""
    local parts = {}
    for part in value:gmatch("[^/]+") do
        if part == ".." then
            assert(#parts > 0, "path escapes its root")
            parts[#parts] = nil
        elseif part ~= "" and part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return prefix .. table.concat(parts, "/")
end

local function safeRelative(value)
    value = tostring(value or ""):gsub("\\", "/")
    if value == "" or value:sub(1, 1) == "/" or value:sub(-1) == "/"
        or value:find("\0", 1, true) or value:find("//", 1, true)
        or value:match("^%a:") then
        return false
    end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return true
end

local function native(value)
    if windows then return tostring(value):gsub("/", "\\") end
    return value
end

local function join(left, right)
    return normalize(tostring(left):gsub("/+$", "") .. "/" .. tostring(right))
end

local function readFile(file_path)
    local handle, open_err = io.open(native(file_path), "rb")
    assert(handle, open_err)
    local content, read_err = handle:read("*a")
    local closed, close_err = handle:close()
    assert(content, read_err)
    assert(closed, close_err)
    return content
end

local function writeFile(file_path, content)
    local handle, open_err = io.open(native(file_path), "wb")
    assert(handle, open_err)
    local wrote, write_err = handle:write(content)
    local flushed, flush_err = handle:flush()
    local closed, close_err = handle:close()
    assert(wrote, write_err)
    assert(flushed, flush_err)
    assert(closed, close_err)
end

local function packU32(value)
    value = value % 4294967296
    local a = math.floor(value / 16777216) % 256
    local b = math.floor(value / 65536) % 256
    local c = math.floor(value / 256) % 256
    local d = value % 256
    return string.char(a, b, c, d)
end

local function quotePosix(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function commandDigest(file_path)
    local commands
    if windows then
        assert(not file_path:find('["%%]'), "unsupported Windows hash path")
        commands = {
            'certutil -hashfile "' .. native(file_path) .. '" SHA256 2>NUL',
        }
    else
        commands = {
            "sha256sum " .. quotePosix(file_path) .. " 2>/dev/null",
            "shasum -a 256 " .. quotePosix(file_path) .. " 2>/dev/null",
        }
    end
    for _, command in ipairs(commands) do
        local pipe = io.popen(command, "r")
        if pipe then
            local output = pipe:read("*a") or ""
            local ok = pipe:close()
            if ok then
                for digest in output:lower():gmatch("[%da-f]+") do
                    if #digest == 64 then return digest end
                end
            end
        end
    end
    error("SHA-256 tool is unavailable")
end

local function cString(value)
    local escaped = {}
    value = tostring(value or "")
    for index = 1, #value do
        escaped[#escaped + 1] = string.format("\\%03o", value:byte(index))
    end
    return '"' .. table.concat(escaped) .. '"'
end

local function emitArray(index, content)
    local lines = {
        string.format("static const unsigned char luai_file_%d[] = {", index),
    }
    if #content == 0 then
        lines[#lines + 1] = "    0x00,"
    else
        for offset = 1, #content, 12 do
            local bytes = {}
            for position = offset, math.min(offset + 11, #content) do
                bytes[#bytes + 1] = string.format("0x%02x", content:byte(position))
            end
            lines[#lines + 1] = "    " .. table.concat(bytes, ", ") .. ","
        end
    end
    lines[#lines + 1] = "};"
    return table.concat(lines, "\n")
end

root = normalize(root)
local manifest_path = join(root, ".luai/build/payload-files.lua")
local manifest_chunk, load_err = loadfile(native(manifest_path))
assert(manifest_chunk, load_err)
local records = manifest_chunk()
assert(type(records) == "table", "payload manifest is not a table")

local files = {}
local hash_parts = {}
local previous
for index, record in ipairs(records) do
    assert(type(record) == "table" and safeRelative(record.path),
        "payload manifest contains an unsafe path")
    assert(type(record.executable) == "boolean", "payload mode is invalid")
    assert(previous == nil or previous < record.path,
        "payload manifest is not strictly sorted")
    previous = record.path
    local content = readFile(join(root, record.path))
    files[index] = {
        path = record.path,
        content = content,
        executable = record.executable,
    }
    hash_parts[#hash_parts + 1] = packU32(#record.path)
    hash_parts[#hash_parts + 1] = record.path
    hash_parts[#hash_parts + 1] = record.executable and "\1" or "\0"
    hash_parts[#hash_parts + 1] = packU32(math.floor(#content / 4294967296))
    hash_parts[#hash_parts + 1] = packU32(#content % 4294967296)
    hash_parts[#hash_parts + 1] = content
end

local output_path = normalize(arg[2] or join(root, ".luai/build/payload.inc"))
local hash_input = output_path .. ".sha256-input"
writeFile(hash_input, table.concat(hash_parts))
local payload_id = commandDigest(hash_input)
assert(os.remove(native(hash_input)), "cannot remove SHA-256 input")

local lines = {}
for index, file in ipairs(files) do
    lines[#lines + 1] = emitArray(index, file.content)
end
lines[#lines + 1] = "#define LUAI_PAYLOAD_ID " .. cString(payload_id)
lines[#lines + 1] = "#define LUAI_FILE_COUNT " .. tostring(#files)
lines[#lines + 1] = "static const struct luai_embedded_file luai_files[] = {"
for index, file in ipairs(files) do
    lines[#lines + 1] = string.format(
        "    { %s, luai_file_%d, %d, %d },",
        cString(file.path),
        index,
        #file.content,
        file.executable and 1 or 0
    )
end
lines[#lines + 1] = "};"
writeFile(output_path, table.concat(lines, "\n\n"))
print(payload_id)
