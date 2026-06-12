local M = {}

M.COURSES = { "python", "lua", "batscript", "miniscript", "moonscript" }

local function sanitize_name(s)
    s = tostring(s or "")
    s = s:gsub("[\r\n]", " ")
    s = s:gsub("|", "/")
    return s
end

function M.new_student(id, name, grades)
    local g = {}
    grades = grades or {}
    for _, c in ipairs(M.COURSES) do
        local v = grades[c]
        if v == nil then
            g[c] = nil
        else
            g[c] = tonumber(v)
        end
    end
    return { id = tonumber(id), name = sanitize_name(name), grades = g }
end

function M.student_to_line(st)
    local parts = {}
    parts[#parts + 1] = tostring(st.id or "")
    parts[#parts + 1] = sanitize_name(st.name or "")
    for _, c in ipairs(M.COURSES) do
        local v = st.grades and st.grades[c] or nil
        if v == nil then
            parts[#parts + 1] = ""
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    return table.concat(parts, "|")
end

function M.student_from_line(line)
    line = tostring(line or "")
    if line == "" then return nil end
    local parts = {}
    for token in string.gmatch(line, "([^|]*)|?") do
        parts[#parts + 1] = token
        if #token == 0 and #parts > 1 and line:sub(-1) ~= "|" and #parts >= (2 + #M.COURSES) then
            break
        end
        if #parts >= (2 + #M.COURSES) then
            break
        end
    end
    if #parts < 2 then return nil end
    local id = tonumber(parts[1])
    local name = parts[2] or ""
    if not id then return nil end
    local grades = {}
    for i, c in ipairs(M.COURSES) do
        local raw = parts[2 + i]
        raw = raw and tostring(raw) or ""
        raw = raw:gsub("\r", ""):gsub("\n", "")
        if raw == "" then
            grades[c] = nil
        else
            local n = tonumber(raw)
            grades[c] = n
        end
    end
    return M.new_student(id, name, grades)
end

return M
