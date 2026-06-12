--[[
Utility helpers for the student management system sample.

Author:
    WaterRun
File:
    utils.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local U = {}

-- @description: Print a line.
-- @param value: any - Value to print.
function U.println(value)
    io.write(tostring(value or ""), "\n")
end

-- @description: Trim whitespace.
-- @param value: any - Raw value.
-- @return: string - Trimmed string.
function U.trim(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

-- @description: Prompt for a raw line.
-- @param message: string - Prompt text.
-- @return: string|nil - User input.
function U.prompt_raw(message)
    io.write(tostring(message or ""))
    return io.read("*l")
end

-- @description: Prompt for an integer.
-- @param message: string - Prompt text.
-- @return: number|nil - Parsed integer.
function U.prompt_int(message)
    local value = U.trim(U.prompt_raw(message) or "")
    if value == "" then
        return nil
    end
    local number = tonumber(value)
    if not number then
        return nil
    end
    return math.floor(number)
end

-- @description: Test whether a file exists.
-- @param path: string - File path.
-- @return: boolean - True when readable.
function U.file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

-- @description: Read a whole file.
-- @param path: string - File path.
-- @return: string|nil, string|nil - Content or nil, plus error.
function U.read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local content = file:read("*a") or ""
    file:close()
    return content
end

-- @description: Write a whole file.
-- @param path: string - File path.
-- @param content: string - File content.
function U.write_file(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content or "")
    file:close()
end

local function cell_str(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

-- @description: Render a plain ASCII table.
-- @param headers: table - Header cells.
-- @param rows: table - Row cells.
-- @return: string - Rendered table.
function U.render_table(headers, rows)
    headers = headers or {}
    rows = rows or {}
    local cols = #headers
    local widths = {}
    for i = 1, cols do
        widths[i] = #cell_str(headers[i])
    end
    for _, row in ipairs(rows) do
        for i = 1, cols do
            local width = #cell_str(row[i])
            if width > widths[i] then
                widths[i] = width
            end
        end
    end

    local function hr()
        local parts = { "+" }
        for i = 1, cols do
            parts[#parts + 1] = string.rep("-", widths[i] + 2)
            parts[#parts + 1] = "+"
        end
        return table.concat(parts)
    end

    local function row_line(row)
        local parts = { "|" }
        for i = 1, cols do
            local value = cell_str(row[i])
            parts[#parts + 1] = " " .. value .. string.rep(" ", widths[i] - #value + 1)
            parts[#parts + 1] = "|"
        end
        return table.concat(parts)
    end

    local out = { hr(), row_line(headers), hr() }
    for _, row in ipairs(rows) do
        out[#out + 1] = row_line(row)
    end
    out[#out + 1] = hr()
    return table.concat(out, "\n")
end

-- @description: Parse command-line options.
-- @param args: table - Raw arg table.
-- @return: string|nil, table - Command and option table.
function U.parse_cli(args)
    local command = nil
    local opts = { positionals = {} }
    local i = 1
    while i <= #args do
        local item = args[i]
        if item:sub(1, 2) == "--" then
            local key = item:sub(3):gsub("-", "_")
            local next_value = args[i + 1]
            if next_value and next_value:sub(1, 2) ~= "--" then
                opts[key] = next_value
                i = i + 2
            else
                opts[key] = true
                i = i + 1
            end
        elseif not command then
            command = item
            i = i + 1
        else
            opts.positionals[#opts.positionals + 1] = item
            i = i + 1
        end
    end
    return command, opts
end

-- @description: Escape a CSV field.
-- @param value: any - Raw value.
-- @return: string - CSV field.
function U.csv_escape(value)
    local text = tostring(value or "")
    if text:find('[,"\n\r]') then
        text = '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

-- @description: Parse a single CSV line.
-- @param line: string - CSV line.
-- @return: table - Field list.
function U.csv_parse_line(line)
    local fields = {}
    local field = {}
    local quoted = false
    local i = 1
    line = tostring(line or "")
    while i <= #line do
        local ch = line:sub(i, i)
        if quoted then
            if ch == '"' and line:sub(i + 1, i + 1) == '"' then
                field[#field + 1] = '"'
                i = i + 2
            elseif ch == '"' then
                quoted = false
                i = i + 1
            else
                field[#field + 1] = ch
                i = i + 1
            end
        else
            if ch == '"' then
                quoted = true
                i = i + 1
            elseif ch == "," then
                fields[#fields + 1] = table.concat(field)
                field = {}
                i = i + 1
            else
                field[#field + 1] = ch
                i = i + 1
            end
        end
    end
    fields[#fields + 1] = table.concat(field)
    return fields
end

-- @description: Split file content into lines.
-- @param content: string - File content.
-- @return: table - Lines.
function U.lines(content)
    content = tostring(content or ""):gsub("\r\n", "\n")
    local out = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

return U
