local U = {}

function U.println(s)
    io.write(tostring(s or ""), "\n")
end

function U.trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

function U.prompt_raw(msg)
    io.write(tostring(msg or ""))
    local s = io.read("*l")
    return s
end

function U.prompt_int(msg)
    local s = U.prompt_raw(msg)
    s = U.trim(s or "")
    if s == "" then return nil end
    local n = tonumber(s)
    if not n then return nil end
    n = math.floor(n)
    return n
end

function U.read_file_lines(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local content = f:read("*a") or ""
    f:close()
    content = content:gsub("\r\n", "\n")
    local lines = {}
    local i = 1
    for line in string.gmatch(content, "([^\n]*)\n?") do
        if line == "" and i > #content then break end
        if line ~= "" then
            lines[#lines + 1] = line
        end
        i = i + 1
        if i > 10000000 then break end
    end
    return lines
end

function U.write_file_lines(path, lines)
    local f = assert(io.open(path, "wb"))
    for i = 1, #lines do
        f:write(tostring(lines[i] or ""), "\n")
    end
    f:close()
end

local function cell_str(x)
    if x == nil then return "" end
    return tostring(x)
end

function U.render_table(headers, rows)
    headers = headers or {}
    rows = rows or {}
    local cols = #headers
    local widths = {}
    for i = 1, cols do
        widths[i] = #cell_str(headers[i])
    end
    for _, r in ipairs(rows) do
        for i = 1, cols do
            local v = cell_str(r[i])
            if #v > widths[i] then widths[i] = #v end
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
    local function row_line(r)
        local parts = { "|" }
        for i = 1, cols do
            local v = cell_str(r[i])
            local pad = widths[i] - #v
            parts[#parts + 1] = " " .. v .. string.rep(" ", pad + 1)
            parts[#parts + 1] = "|"
        end
        return table.concat(parts)
    end
    local out = {}
    out[#out + 1] = hr()
    out[#out + 1] = row_line(headers)
    out[#out + 1] = hr()
    for _, r in ipairs(rows) do
        out[#out + 1] = row_line(r)
    end
    out[#out + 1] = hr()
    return table.concat(out, "\n")
end

return U
