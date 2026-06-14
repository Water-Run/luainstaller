#!/usr/bin/env lua
--[[
Student management system sample entry point.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local SOURCE_DIR = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = SOURCE_DIR .. "/?.lua;" .. package.path

local model = require("model")
local reports = require("reports")
local service_mod = require("service")
local utils = require("utils")

local function grade_cell(student, course)
    return model.format_grade(student.grades and student.grades[course])
end

local function student_rows(students)
    local rows = {}
    for _, student in ipairs(students) do
        rows[#rows + 1] = {
            student.id,
            student.name,
            student.gender,
            student.class_name,
            string.format("%.2f", model.average(student)),
            grade_cell(student, "lua"),
            grade_cell(student, "python"),
            grade_cell(student, "math"),
            grade_cell(student, "english"),
        }
    end
    return rows
end

local function print_students(students)
    utils.println(utils.render_table(
        { "ID", "NAME", "G", "CLASS", "AVG", "LUA", "PY", "MATH", "ENG" },
        student_rows(students)
    ))
    utils.println("Count: " .. tostring(#students))
end

local function print_student(student)
    if not student then
        utils.println("Student not found")
        return
    end
    local rows = {
        { "ID", student.id },
        { "Name", student.name },
        { "Gender", student.gender },
        { "Class", student.class_name },
        { "Birth Year", student.birth_year or "" },
        { "Phone", student.phone },
        { "Email", student.email },
        { "Average", string.format("%.2f", model.average(student)) },
        { "GPA", string.format("%.2f", model.gpa(student)) },
    }
    for _, course in ipairs(model.COURSES) do
        rows[#rows + 1] = { model.COURSE_LABELS[course], grade_cell(student, course) }
    end
    utils.println(utils.render_table({ "FIELD", "VALUE" }, rows))
end

local function parse_student_options(opts)
    local grades, err = model.parse_grade_expr(opts.grades or "")
    if err then
        return nil, err
    end
    return {
        name = opts.name,
        gender = opts.gender,
        class_name = opts.class or opts.class_name,
        birth_year = opts.birth or opts.birth_year,
        phone = opts.phone,
        email = opts.email,
        grades = grades,
    }
end

local function parse_update_options(opts)
    local fields = {}
    if opts.name then
        fields.name = opts.name
    end
    if opts.gender then
        fields.gender = opts.gender
    end
    if opts.class or opts.class_name then
        fields.class_name = opts.class or opts.class_name
    end
    if opts.birth or opts.birth_year then
        fields.birth_year = opts.birth or opts.birth_year
    end
    if opts.phone then
        fields.phone = opts.phone
    end
    if opts.email then
        fields.email = opts.email
    end
    if opts.grades and opts.grades ~= "" then
        local grades, err = model.parse_grade_expr(opts.grades)
        if err then
            return nil, err
        end
        fields.grades = grades
    end
    return fields
end

local function print_stats(svc)
    local stats = svc:stats()
    utils.println("Total students: " .. stats.total)
    utils.println(string.format("Average score: %.2f", stats.average))
    utils.println(string.format("Passing: %d (%.2f%%)", stats.passing, stats.pass_rate))
end

local function print_report(svc)
    utils.println("Class Summary")
    local rows = {}
    for _, row in ipairs(reports.class_summary(svc:list())) do
        rows[#rows + 1] = {
            row.class_name,
            row.count,
            string.format("%.2f", row.average),
            string.format("%.2f%%", row.pass_rate),
        }
    end
    utils.println(utils.render_table({ "CLASS", "COUNT", "AVG", "PASS RATE" }, rows))
end

local function print_rank(svc, course)
    course = tostring(course or "average"):lower()
    local title = course == "average" and "Average Ranking"
        or ((model.COURSE_LABELS[course] or course) .. " Ranking")
    utils.println(title)
    local rows = {}
    for rank, row in ipairs(reports.ranking(svc:list(), course)) do
        rows[#rows + 1] = {
            rank,
            row.student.id,
            row.student.name,
            string.format("%.2f", row.score),
        }
    end
    utils.println(utils.render_table({ "RANK", "ID", "NAME", "SCORE" }, rows))
end

local function run_command(command, opts)
    local data_path = opts.data or "students.json"
    local svc = service_mod.new(data_path)

    if command == "seed" then
        local count = svc:seed(true)
        utils.println("Seeded " .. count .. " students")
    elseif command == "list" then
        print_students(svc:list({ sort = opts.sort, class_name = opts.class }))
    elseif command == "view" then
        print_student(svc:get(opts.id or opts.positionals[1]))
    elseif command == "search" then
        print_students(svc:list({ name = opts.name or opts.positionals[1], class_name = opts.class }))
    elseif command == "add" then
        local fields, err = parse_student_options(opts)
        if not fields then
            error(err)
        end
        local student, add_err = svc:add(fields)
        if not student then
            error(add_err)
        end
        utils.println("Added student " .. student.id .. ": " .. student.name)
    elseif command == "update" then
        local id = tonumber(opts.id or opts.positionals[1])
        if not id then
            error("update requires --id")
        end
        local fields, err = parse_update_options(opts)
        if not fields then
            error(err)
        end
        if next(fields) == nil then
            error("update requires at least one field to change")
        end
        local ok, update_err = svc:update(id, fields)
        if not ok then
            error(update_err)
        end
        utils.println("Updated student " .. id)
    elseif command == "delete" then
        local ok, err = svc:delete(opts.id or opts.positionals[1])
        if not ok then
            error(err)
        end
        utils.println("Deleted student")
    elseif command == "stats" then
        print_stats(svc)
    elseif command == "report" then
        print_report(svc)
    elseif command == "rank" then
        print_rank(svc, opts.course or opts.positionals[1] or "average")
    elseif command == "export" then
        local out = opts.out or opts.file or "students.csv"
        svc:export_csv(out)
        utils.println("Exported " .. out)
    elseif command == "import" then
        local file = opts.file or opts.positionals[1]
        if not file then
            error("import requires --file")
        end
        local count, err = svc:import_csv(file)
        if err then
            error(err)
        end
        utils.println("Imported " .. count .. " students")
    elseif command == "backup" then
        local backup_path = svc:backup()
        utils.println(backup_path and ("Backup written: " .. backup_path) or "No data file to back up")
    else
        error("unknown command: " .. tostring(command))
    end
end

local function prompt_grades(existing)
    local grades = {}
    for _, course in ipairs(model.COURSES) do
        local current = existing and existing.grades and existing.grades[course]
        local label = model.COURSE_LABELS[course]
        local prompt = label .. " (0-100)"
        if current ~= nil then
            prompt = prompt .. " [" .. model.format_grade(current) .. "]"
        end
        prompt = prompt .. ": "
        local value = utils.trim(utils.prompt_raw(prompt) or "")
        if value == "" then
            grades[course] = current
        else
            grades[course] = value
        end
    end
    return grades
end

local function interactive_add(svc)
    local fields = {}
    fields.name = utils.prompt_raw("Name: ")
    fields.gender = utils.prompt_raw("Gender (M/F/U): ")
    fields.class_name = utils.prompt_raw("Class: ")
    fields.birth_year = utils.prompt_raw("Birth year: ")
    fields.phone = utils.prompt_raw("Phone: ")
    fields.email = utils.prompt_raw("Email: ")
    fields.grades = prompt_grades(nil)
    local student, err = svc:add(fields)
    utils.println(student and ("Added student " .. student.id) or ("Error: " .. err))
end

local function interactive_update(svc)
    local id = utils.prompt_int("Student ID: ")
    local current = svc:get(id)
    if not current then
        utils.println("Student not found")
        return
    end
    local fields = {}
    local name = utils.trim(utils.prompt_raw("Name [" .. current.name .. "]: ") or "")
    if name ~= "" then
        fields.name = name
    end
    local class_name = utils.trim(utils.prompt_raw("Class [" .. current.class_name .. "]: ") or "")
    if class_name ~= "" then
        fields.class_name = class_name
    end
    fields.grades = prompt_grades(current)
    local ok, err = svc:update(id, fields)
    utils.println(ok and "Updated" or ("Error: " .. err))
end

local function show_menu()
    utils.println("")
    utils.println("+--------------------------------------+")
    utils.println("| STUDENT MANAGEMENT SYSTEM (JSON)     |")
    utils.println("+--------------------------------------+")
    utils.println("| 1) List students                     |")
    utils.println("| 2) View student                      |")
    utils.println("| 3) Add student                       |")
    utils.println("| 4) Update student                    |")
    utils.println("| 5) Delete student                    |")
    utils.println("| 6) Class report                      |")
    utils.println("| 7) Ranking                           |")
    utils.println("| 8) Seed sample data                  |")
    utils.println("| 0) Exit                              |")
    utils.println("+--------------------------------------+")
end

local function run_interactive(data_path)
    local svc = service_mod.new(data_path or "students.json")
    while true do
        show_menu()
        local choice = utils.trim(utils.prompt_raw("Select: ") or "")
        if choice == "1" then
            print_students(svc:list())
        elseif choice == "2" then
            print_student(svc:get(utils.prompt_int("Student ID: ")))
        elseif choice == "3" then
            interactive_add(svc)
        elseif choice == "4" then
            interactive_update(svc)
        elseif choice == "5" then
            local ok, err = svc:delete(utils.prompt_int("Student ID: "))
            utils.println(ok and "Deleted" or ("Error: " .. err))
        elseif choice == "6" then
            print_report(svc)
        elseif choice == "7" then
            print_rank(svc, utils.prompt_raw("Course or average: "))
        elseif choice == "8" then
            utils.println("Seeded " .. svc:seed(true) .. " students")
        elseif choice == "0" then
            return
        else
            utils.println("Unknown option")
        end
    end
end

local command, opts = utils.parse_cli(arg or {})
local ok, err = pcall(function()
    if command then
        run_command(command, opts)
    else
        run_interactive(opts.data)
    end
end)

if not ok then
    io.stderr:write("Error: " .. tostring(err) .. "\n")
    os.exit(1)
end
