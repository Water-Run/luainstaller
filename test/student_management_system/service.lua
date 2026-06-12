--[[
Business service for the student management system sample.

Author:
    WaterRun
File:
    service.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local model = require("model")
local storage = require("storage")
local utils = require("utils")

local S = {}
S.__index = S

local SEED_STUDENTS = {
    { name = "Ada Lovelace", gender = "F", class_name = "CS1", birth_year = 2003, phone = "5550101", email = "ada@example.test", grades = { lua = 98, python = 95, math = 99, english = 91 } },
    { name = "Grace Hopper", gender = "F", class_name = "CS1", birth_year = 2002, phone = "5550102", email = "grace@example.test", grades = { lua = 92, python = 97, math = 94, english = 90 } },
    { name = "Alan Turing", gender = "M", class_name = "CS1", birth_year = 2001, phone = "5550103", email = "alan@example.test", grades = { lua = 88, python = 90, math = 100, english = 86 } },
    { name = "Linus Torvalds", gender = "M", class_name = "CS2", birth_year = 2004, phone = "5550104", email = "linus@example.test", grades = { lua = 82, python = 84, math = 87, english = 78 } },
    { name = "Barbara Liskov", gender = "F", class_name = "CS2", birth_year = 2003, phone = "5550105", email = "barbara@example.test", grades = { lua = 91, python = 89, math = 93, english = 92 } },
    { name = "Donald Knuth", gender = "M", class_name = "CS2", birth_year = 2002, phone = "5550106", email = "donald@example.test", grades = { lua = 76, python = 80, math = 96, english = 75 } },
    { name = "Margaret Hamilton", gender = "F", class_name = "CS3", birth_year = 2004, phone = "5550107", email = "margaret@example.test", grades = { lua = 94, python = 92, math = 90, english = 96 } },
    { name = "Ken Thompson", gender = "M", class_name = "CS3", birth_year = 2001, phone = "5550108", email = "ken@example.test", grades = { lua = 85, python = 81, math = 88, english = 80 } },
}

local function sort_by_id(a, b)
    return (a.id or 0) < (b.id or 0)
end

local function clone_student(student)
    local copy = {}
    for key, value in pairs(student) do
        if key == "grades" then
            copy.grades = {}
            for course, grade in pairs(value or {}) do
                copy.grades[course] = grade
            end
        else
            copy[key] = value
        end
    end
    return copy
end

local function rebuild_index(self)
    self.by_id = {}
    table.sort(self.data.students, sort_by_id)
    local max_id = 0
    for _, student in ipairs(self.data.students) do
        self.by_id[student.id] = student
        if student.id > max_id then
            max_id = student.id
        end
    end
    if self.data.next_id <= max_id then
        self.data.next_id = max_id + 1
    end
end

local function normalize_loaded(data)
    local students = {}
    for _, raw in ipairs(data.students or {}) do
        local student = model.new_student(raw)
        if student and raw.id then
            student.id = math.floor(tonumber(raw.id))
            students[#students + 1] = student
        end
    end
    data.students = students
    return data
end

function S:load()
    self.data = normalize_loaded(storage.load(self.path))
    rebuild_index(self)
end

function S:save()
    rebuild_index(self)
    storage.save(self.path, self.data)
end

function S:backup()
    return storage.backup(self.path)
end

function S:seed(force)
    if #self.data.students > 0 and not force then
        return 0
    end
    self.data.students = {}
    self.data.next_id = 1
    for _, raw in ipairs(SEED_STUDENTS) do
        self:add(raw, false)
    end
    self:save()
    return #SEED_STUDENTS
end

function S:add(fields, autosave)
    fields = fields or {}
    fields.id = self.data.next_id
    local student, err = model.new_student(fields)
    if not student then
        return nil, err
    end
    self.data.next_id = self.data.next_id + 1
    self.data.students[#self.data.students + 1] = student
    rebuild_index(self)
    if autosave ~= false then
        self:save()
    end
    return clone_student(student)
end

function S:update(id, fields)
    id = tonumber(id)
    local current = id and self.by_id[id]
    if not current then
        return false, "student not found"
    end
    local merged = clone_student(current)
    for key, value in pairs(fields or {}) do
        if key == "grades" then
            merged.grades = merged.grades or {}
            for course, grade in pairs(value) do
                merged.grades[course] = grade
            end
        else
            merged[key] = value
        end
    end
    merged.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local student, err = model.new_student(merged)
    if not student then
        return false, err
    end
    student.id = id
    for key in pairs(current) do
        current[key] = nil
    end
    for key, value in pairs(student) do
        current[key] = value
    end
    self:save()
    return true
end

function S:delete(id)
    id = tonumber(id)
    if not id or not self.by_id[id] then
        return false, "student not found"
    end
    local next_students = {}
    for _, student in ipairs(self.data.students) do
        if student.id ~= id then
            next_students[#next_students + 1] = student
        end
    end
    self.data.students = next_students
    rebuild_index(self)
    self:save()
    return true
end

function S:get(id)
    id = tonumber(id)
    local student = id and self.by_id[id]
    return student and clone_student(student) or nil
end

function S:list(opts)
    opts = opts or {}
    local rows = {}
    local query = model.trim(opts.name or ""):lower()
    local class_name = model.trim(opts.class_name or opts.class or "")
    for _, student in ipairs(self.data.students) do
        local matches_name = query == "" or student.name:lower():find(query, 1, true) ~= nil
        local matches_class = class_name == "" or student.class_name == class_name
        if matches_name and matches_class then
            rows[#rows + 1] = clone_student(student)
        end
    end
    local sort = tostring(opts.sort or "id"):lower()
    table.sort(rows, function(a, b)
        if sort == "average" then
            if model.average(a) == model.average(b) then
                return a.id < b.id
            end
            return model.average(a) > model.average(b)
        elseif sort == "name" then
            return a.name < b.name
        elseif sort == "class" then
            if a.class_name == b.class_name then
                return a.id < b.id
            end
            return a.class_name < b.class_name
        end
        return a.id < b.id
    end)
    return rows
end

function S:export_csv(path)
    local header = { "name", "gender", "class", "birth_year", "phone", "email" }
    for _, course in ipairs(model.COURSES) do
        header[#header + 1] = course
    end
    local lines = { table.concat(header, ",") }
    for _, student in ipairs(self:list()) do
        local row = {
            utils.csv_escape(student.name),
            utils.csv_escape(student.gender),
            utils.csv_escape(student.class_name),
            utils.csv_escape(student.birth_year or ""),
            utils.csv_escape(student.phone),
            utils.csv_escape(student.email),
        }
        for _, course in ipairs(model.COURSES) do
            row[#row + 1] = utils.csv_escape(student.grades[course] or "")
        end
        lines[#lines + 1] = table.concat(row, ",")
    end
    utils.write_file(path, table.concat(lines, "\n") .. "\n")
end

function S:import_csv(path)
    local content = assert(utils.read_file(path))
    local lines = utils.lines(content)
    local count = 0
    for i = 2, #lines do
        if utils.trim(lines[i]) ~= "" then
            local row = utils.csv_parse_line(lines[i])
            local grades = {}
            for course_index, course in ipairs(model.COURSES) do
                grades[course] = row[6 + course_index]
            end
            local student, err = self:add({
                name = row[1],
                gender = row[2],
                class_name = row[3],
                birth_year = row[4],
                phone = row[5],
                email = row[6],
                grades = grades,
            }, false)
            if not student then
                return count, err
            end
            count = count + 1
        end
    end
    self:save()
    return count
end

function S:stats()
    local total = #self.data.students
    local passing = 0
    local average = 0
    for _, student in ipairs(self.data.students) do
        average = average + model.average(student)
        if model.is_passing(student) then
            passing = passing + 1
        end
    end
    if total > 0 then
        average = average / total
    end
    return {
        total = total,
        passing = passing,
        average = average,
        pass_rate = total == 0 and 0 or passing * 100 / total,
    }
end

local M = {}

function M.new(path)
    local self = setmetatable({}, S)
    self.path = tostring(path or "students.json")
    self.data = { version = 1, next_id = 1, students = {} }
    self.by_id = {}
    self:load()
    return self
end

return M
