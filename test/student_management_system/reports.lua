--[[
Report helpers for the student management system sample.

Author:
    WaterRun
File:
    reports.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local model = require("model")

local M = {}

-- @description: Build class-level summary rows.
-- @param students: table - Student list.
-- @return: table - Summary rows.
function M.class_summary(students)
    local by_class = {}
    for _, student in ipairs(students) do
        local class_name = student.class_name or "UNASSIGNED"
        local row = by_class[class_name]
        if not row then
            row = { class_name = class_name, count = 0, total_average = 0, passing = 0 }
            by_class[class_name] = row
        end
        row.count = row.count + 1
        row.total_average = row.total_average + model.average(student)
        if model.is_passing(student) then
            row.passing = row.passing + 1
        end
    end

    local rows = {}
    for _, row in pairs(by_class) do
        row.average = row.count == 0 and 0 or row.total_average / row.count
        row.pass_rate = row.count == 0 and 0 or row.passing * 100 / row.count
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        return a.class_name < b.class_name
    end)
    return rows
end

-- @description: Build ranking rows for a course or average.
-- @param students: table - Student list.
-- @param course: string - Course name or "average".
-- @return: table - Ranking rows.
function M.ranking(students, course)
    course = tostring(course or "average"):lower()
    local rows = {}
    for _, student in ipairs(students) do
        local score
        if course == "average" then
            score = model.average(student)
        else
            score = student.grades and student.grades[course] or 0
        end
        rows[#rows + 1] = { student = student, score = score }
    end
    table.sort(rows, function(a, b)
        if a.score == b.score then
            return a.student.id < b.student.id
        end
        return a.score > b.score
    end)
    return rows
end

return M
