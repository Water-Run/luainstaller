--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    11_table_serializer.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local student = {
    id = 1001,
    name = "Ada",
    courses = { "math", "logic", "programming" },
}

local function quote(value)
    return string.format("%q", tostring(value))
end

print("{")
print("  id = " .. student.id .. ",")
print("  name = " .. quote(student.name) .. ",")
local quoted_courses = {}
for _, course in ipairs(student.courses) do
    quoted_courses[#quoted_courses + 1] = quote(course)
end
print("  courses = { " .. table.concat(quoted_courses, ", ") .. " },")
print("}")
