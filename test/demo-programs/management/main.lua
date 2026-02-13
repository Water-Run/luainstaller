local model = require("model")
local service_mod = require("service")
local utils = require("utils")

local DATA_FILE = "students.txt"

local function format_grade(v)
    if v == nil then return "-" end
    if type(v) == "number" then
        if v == math.floor(v) then return tostring(v) end
        return string.format("%.2f", v)
    end
    return tostring(v)
end

local function collect_grades(existing)
    local grades = {}
    for _, c in ipairs(model.COURSES) do
        local cur = existing and existing.grades and existing.grades[c] or nil
        while true do
            local prompt = c .. " (0-100)"
            if cur ~= nil then
                prompt = prompt .. " [" .. format_grade(cur) .. "]"
            end
            prompt = prompt .. ": "
            local s = utils.prompt_raw(prompt)
            s = utils.trim(s or "")
            if s == "" then
                grades[c] = cur
                break
            end
            local n = tonumber(s)
            if n and n >= 0 and n <= 100 then
                if n == math.floor(n) then
                    grades[c] = math.floor(n)
                else
                    grades[c] = n
                end
                break
            end
            utils.println("Invalid grade. Use a number 0-100 or empty.")
        end
    end
    return grades
end

local function student_rows(students)
    local rows = {}
    for _, st in ipairs(students) do
        local row = {}
        row[#row + 1] = tostring(st.id)
        row[#row + 1] = st.name
        for _, c in ipairs(model.COURSES) do
            row[#row + 1] = format_grade(st.grades[c])
        end
        rows[#rows + 1] = row
    end
    return rows
end

local function show_list(svc)
    local headers = { "ID", "NAME" }
    for _, c in ipairs(model.COURSES) do
        headers[#headers + 1] = string.upper(c)
    end
    local students = svc:all()
    local rows = student_rows(students)
    utils.println(utils.render_table(headers, rows))
    utils.println("Count: " .. tostring(#students))
end

local function show_one(svc)
    local id = utils.prompt_int("Enter ID: ")
    if not id then
        utils.println("Invalid ID.")
        return
    end
    local st = svc:get(id)
    if not st then
        utils.println("Not found.")
        return
    end
    local headers = { "FIELD", "VALUE" }
    local rows = {}
    rows[#rows + 1] = { "ID", tostring(st.id) }
    rows[#rows + 1] = { "NAME", st.name }
    for _, c in ipairs(model.COURSES) do
        rows[#rows + 1] = { string.upper(c), format_grade(st.grades[c]) }
    end
    utils.println(utils.render_table(headers, rows))
end

local function add_student(svc)
    local name = utils.trim(utils.prompt_raw("Name: ") or "")
    if name == "" then
        utils.println("Name required.")
        return
    end
    local grades = collect_grades(nil)
    local st = svc:add(name, grades)
    svc:save()
    utils.println("Added ID " .. tostring(st.id))
end

local function update_student(svc)
    local id = utils.prompt_int("Enter ID to update: ")
    if not id then
        utils.println("Invalid ID.")
        return
    end
    local st = svc:get(id)
    if not st then
        utils.println("Not found.")
        return
    end
    local name = utils.prompt_raw("Name [" .. st.name .. "]: ")
    name = utils.trim(name or "")
    if name == "" then name = st.name end
    local grades = collect_grades(st)
    local ok = svc:update(id, { name = name, grades = grades })
    if ok then
        svc:save()
        utils.println("Updated.")
    else
        utils.println("Update failed.")
    end
end

local function delete_student(svc)
    local id = utils.prompt_int("Enter ID to delete: ")
    if not id then
        utils.println("Invalid ID.")
        return
    end
    local st = svc:get(id)
    if not st then
        utils.println("Not found.")
        return
    end
    utils.println("Delete: ID=" .. tostring(st.id) .. " NAME=" .. st.name)
    local yn = utils.trim(utils.prompt_raw("Confirm (y/N): ") or "")
    yn = string.lower(yn)
    if yn ~= "y" and yn ~= "yes" then
        utils.println("Canceled.")
        return
    end
    local ok = svc:delete(id)
    if ok then
        svc:save()
        utils.println("Deleted.")
    else
        utils.println("Delete failed.")
    end
end

local function show_menu()
    utils.println("")
    utils.println("+--------------------------------------+")
    utils.println("| STUDENT GRADE MANAGER (TXT STORAGE)  |")
    utils.println("+--------------------------------------+")
    utils.println("| 1) List students                     |")
    utils.println("| 2) View student by ID                |")
    utils.println("| 3) Add student                       |")
    utils.println("| 4) Update student                    |")
    utils.println("| 5) Delete student                    |")
    utils.println("| 6) Save                              |")
    utils.println("| 0) Exit                              |")
    utils.println("+--------------------------------------+")
end

local svc = service_mod.new(DATA_FILE)
svc:load()

while true do
    show_menu()
    local choice = utils.trim(utils.prompt_raw("Select: ") or "")
    if choice == "1" then
        show_list(svc)
    elseif choice == "2" then
        show_one(svc)
    elseif choice == "3" then
        add_student(svc)
    elseif choice == "4" then
        update_student(svc)
    elseif choice == "5" then
        delete_student(svc)
    elseif choice == "6" then
        svc:save()
        utils.println("Saved.")
    elseif choice == "0" then
        svc:save()
        break
    else
        utils.println("Unknown option.")
    end
end
