--[[
Student domain model for the student management system sample.

Author:
    WaterRun
File:
    model.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local M = {}

M.COURSES = { "lua", "python", "math", "english" }
M.COURSE_LABELS = {
    lua = "Lua",
    python = "Python",
    math = "Math",
    english = "English",
}

local COURSE_SET = {}
for _, course in ipairs(M.COURSES) do
    COURSE_SET[course] = true
end

-- @description: Return true when the course is part of the sample curriculum.
-- @param course: string - Course identifier.
-- @return: boolean - True when known.
function M.is_course(course)
    return COURSE_SET[tostring(course or "")] == true
end

-- @description: Trim surrounding whitespace.
-- @param value: any - Value to convert to string and trim.
-- @return: string - Trimmed string.
function M.trim(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

-- @description: Sanitize human text fields for table display and CSV export.
-- @param value: any - Raw field value.
-- @return: string - Sanitized text.
function M.clean_text(value)
    local text = M.trim(value)
    text = text:gsub("[%z\1-\8\11\12\14-\31]", " ")
    text = text:gsub("[\r\n]", " ")
    return text
end

-- @description: Normalize a gender marker.
-- @param value: any - Raw gender value.
-- @return: string - "M", "F", or "U".
function M.normalize_gender(value)
    local text = M.clean_text(value):upper()
    if text == "M" or text == "MALE" then
        return "M"
    end
    if text == "F" or text == "FEMALE" then
        return "F"
    end
    return "U"
end

-- @description: Normalize and validate one grade.
-- @param value: any - Raw grade value.
-- @return: number|nil, string|nil - Grade or nil, plus error message.
function M.normalize_grade(value)
    if value == nil or value == "" then
        return nil
    end
    local grade = tonumber(value)
    if not grade then
        return nil, "grade must be a number"
    end
    if grade < 0 or grade > 100 then
        return nil, "grade must be between 0 and 100"
    end
    if grade == math.floor(grade) then
        grade = math.floor(grade)
    end
    return grade
end

-- @description: Normalize a grade map.
-- @param grades: table|nil - Raw grade table.
-- @return: table, string|nil - Normalized grade table and optional error.
function M.normalize_grades(grades)
    local out = {}
    grades = grades or {}
    for _, course in ipairs(M.COURSES) do
        local grade, err = M.normalize_grade(grades[course])
        if err then
            return nil, course .. ": " .. err
        end
        out[course] = grade
    end
    return out
end

-- @description: Parse a comma-separated grade expression.
-- @param text: string - Example: "lua=90,python=88".
-- @return: table, string|nil - Grade table and optional error.
function M.parse_grade_expr(text)
    local grades = {}
    text = M.trim(text)
    if text == "" then
        return grades
    end
    for item in text:gmatch("[^,]+") do
        local key, value = item:match("^%s*([%w_]+)%s*=%s*([^,]+)%s*$")
        if not key then
            return nil, "invalid grade item: " .. item
        end
        key = key:lower()
        if not M.is_course(key) then
            return nil, "unknown course: " .. key
        end
        grades[key] = value
    end
    return M.normalize_grades(grades)
end

-- @description: Create a normalized student record.
-- @param fields: table - Raw fields.
-- @return: table, string|nil - Student record and optional error.
function M.new_student(fields)
    fields = fields or {}
    local name = M.clean_text(fields.name)
    if name == "" then
        return nil, "name is required"
    end

    local grades, err = M.normalize_grades(fields.grades)
    if err then
        return nil, err
    end

    local birth_year = tonumber(fields.birth_year)
    if birth_year then
        birth_year = math.floor(birth_year)
    end

    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local id = tonumber(fields.id)
    if id then
        id = math.floor(id)
    end

    return {
        id = id,
        name = name,
        gender = M.normalize_gender(fields.gender),
        class_name = M.clean_text(fields.class_name or fields.class or "UNASSIGNED"),
        birth_year = birth_year,
        phone = M.clean_text(fields.phone),
        email = M.clean_text(fields.email),
        grades = grades,
        created_at = fields.created_at or now,
        updated_at = fields.updated_at or now,
    }
end

-- @description: Return total score for available grades.
-- @param student: table - Student record.
-- @return: number - Total score.
function M.total(student)
    local total = 0
    for _, course in ipairs(M.COURSES) do
        total = total + (student.grades and student.grades[course] or 0)
    end
    return total
end

-- @description: Return average score for available curriculum courses.
-- @param student: table - Student record.
-- @return: number - Average score.
function M.average(student)
    return M.total(student) / #M.COURSES
end

-- @description: Return a simple 4-point GPA.
-- @param student: table - Student record.
-- @return: number - GPA value.
function M.gpa(student)
    return M.average(student) / 25
end

-- @description: Return true when every course is at least 60.
-- @param student: table - Student record.
-- @return: boolean - True when passing.
function M.is_passing(student)
    for _, course in ipairs(M.COURSES) do
        if (student.grades and student.grades[course] or 0) < 60 then
            return false
        end
    end
    return true
end

-- @description: Format a grade for terminal output.
-- @param value: number|nil - Grade.
-- @return: string - Display string.
function M.format_grade(value)
    if value == nil then
        return "-"
    end
    if value == math.floor(value) then
        return tostring(value)
    end
    return string.format("%.2f", value)
end

return M
