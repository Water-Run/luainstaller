local model = require("model")
local utils = require("utils")

local S = {}
S.__index = S

local function sort_by_id(a, b)
    return (a.id or 0) < (b.id or 0)
end

local function rebuild_index(self)
    self.by_id = {}
    for _, st in ipairs(self.students) do
        self.by_id[st.id] = st
    end
    table.sort(self.students, sort_by_id)
end

local function next_id(self)
    local max_id = 0
    for _, st in ipairs(self.students) do
        if st.id and st.id > max_id then
            max_id = st.id
        end
    end
    return max_id + 1
end

function S:load()
    self.students = {}
    self.by_id = {}
    local lines = utils.read_file_lines(self.path)
    for _, line in ipairs(lines) do
        local st = model.student_from_line(line)
        if st then
            self.students[#self.students + 1] = st
        end
    end
    rebuild_index(self)
    self.dirty = false
end

function S:save()
    local lines = {}
    table.sort(self.students, sort_by_id)
    for _, st in ipairs(self.students) do
        lines[#lines + 1] = model.student_to_line(st)
    end
    utils.write_file_lines(self.path, lines)
    self.dirty = false
end

function S:all()
    local out = {}
    for i = 1, #self.students do
        out[i] = self.students[i]
    end
    table.sort(out, sort_by_id)
    return out
end

function S:get(id)
    id = tonumber(id)
    if not id then return nil end
    return self.by_id[id]
end

function S:add(name, grades)
    local id = next_id(self)
    local st = model.new_student(id, name, grades or {})
    self.students[#self.students + 1] = st
    self.by_id[id] = st
    self.dirty = true
    rebuild_index(self)
    return st
end

function S:update(id, fields)
    id = tonumber(id)
    if not id then return false end
    local st = self.by_id[id]
    if not st then return false end
    fields = fields or {}
    if fields.name ~= nil then
        st.name = tostring(fields.name)
        st.name = st.name:gsub("[\r\n]", " "):gsub("|", "/")
    end
    if fields.grades ~= nil then
        st.grades = st.grades or {}
        for _, c in ipairs(model.COURSES) do
            local v = fields.grades[c]
            if v == nil then
                st.grades[c] = st.grades[c]
            else
                st.grades[c] = tonumber(v)
            end
        end
    end
    self.dirty = true
    rebuild_index(self)
    return true
end

function S:delete(id)
    id = tonumber(id)
    if not id then return false end
    if not self.by_id[id] then return false end
    local new_list = {}
    for _, st in ipairs(self.students) do
        if st.id ~= id then
            new_list[#new_list + 1] = st
        end
    end
    self.students = new_list
    rebuild_index(self)
    self.dirty = true
    return true
end

local M = {}

function M.new(path)
    local o = setmetatable({}, S)
    o.path = tostring(path or "students.txt")
    o.students = {}
    o.by_id = {}
    o.dirty = false
    return o
end

return M
