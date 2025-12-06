-- utils.lua
-- 工具函数模块
-- 提供通用的辅助函数

local utils = {}

-----------------------------------------------------------
-- 字符串处理
-----------------------------------------------------------

function utils.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return s:match("^%s*(.-)%s*$") or ""
end

function utils.split(s, delimiter)
    if type(s) ~= "string" then
        return {}
    end
    delimiter = delimiter or ","
    local result = {}
    for part in s:gmatch("([^" .. delimiter .. "]+)") do
        table.insert(result, utils.trim(part))
    end
    return result
end

function utils.pad_right(s, width)
    s = tostring(s)
    local len = #s
    if len >= width then
        return s:sub(1, width)
    end
    return s .. string.rep(" ", width - len)
end

function utils.pad_left(s, width)
    s = tostring(s)
    local len = #s
    if len >= width then
        return s:sub(1, width)
    end
    return string.rep(" ", width - len) .. s
end

-----------------------------------------------------------
-- 数值处理
-----------------------------------------------------------

function utils.round(num, decimals)
    decimals = decimals or 2
    local mult = 10 ^ decimals
    return math.floor(num * mult + 0.5) / mult
end

function utils.is_valid_score(score)
    local n = tonumber(score)
    return n ~= nil and n >= 0 and n <= 100
end

function utils.is_positive_integer(s)
    local n = tonumber(s)
    return n ~= nil and n > 0 and n == math.floor(n)
end

-----------------------------------------------------------
-- 表格处理
-----------------------------------------------------------

function utils.table_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = utils.table_copy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

function utils.table_keys(t)
    local keys = {}
    for k, _ in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    return keys
end

-----------------------------------------------------------
-- 输入输出
-----------------------------------------------------------

function utils.prompt(message)
    io.write(message)
    io.flush()
    local input = io.read("*l")
    if input then
        return utils.trim(input)
    end
    return nil
end

function utils.confirm(message)
    local answer = utils.prompt(message .. " (y/n): ")
    return answer and (answer:lower() == "y" or answer:lower() == "yes")
end

function utils.print_line(char, width)
    char = char or "-"
    width = width or 60
    print(string.rep(char, width))
end

function utils.print_header(title)
    utils.print_line("=")
    print("  " .. title)
    utils.print_line("=")
end

-----------------------------------------------------------
-- 日期时间
-----------------------------------------------------------

function utils.get_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function utils.get_date()
    return os.date("%Y-%m-%d")
end

return utils