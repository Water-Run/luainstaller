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
print("  courses = { " .. quote(table.concat(student.courses, ", ")) .. " },")
print("}")
