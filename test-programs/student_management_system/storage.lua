-- storage.lua
-- 数据持久化模块
-- 负责学生数据的文件读写

local utils = require("utils")
local student = require("student")

local storage = {}

local DEFAULT_FILE = "students.dat"

-----------------------------------------------------------
-- 文件操作
-----------------------------------------------------------

function storage.file_exists(filepath)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        return true
    end
    return false
end

function storage.get_filepath(filename)
    return filename or DEFAULT_FILE
end

-----------------------------------------------------------
-- 保存数据
-----------------------------------------------------------

function storage.save(students, filename)
    local filepath = storage.get_filepath(filename)
    
    local file, err = io.open(filepath, "w")
    if not file then
        return false, "无法打开文件进行写入: " .. (err or "未知错误")
    end
    
    file:write("# 学生成绩管理系统数据文件\n")
    file:write("# 生成时间: " .. utils.get_timestamp() .. "\n")
    file:write("# 格式: 学号|姓名|班级|成绩(科目:分数;...)|创建时间|更新时间\n")
    file:write("\n")
    
    local count = 0
    for _, stu in pairs(students) do
        local line = student.serialize(stu)
        file:write(line .. "\n")
        count = count + 1
    end
    
    file:close()
    return true, count
end

-----------------------------------------------------------
-- 加载数据
-----------------------------------------------------------

function storage.load(filename)
    local filepath = storage.get_filepath(filename)
    
    if not storage.file_exists(filepath) then
        return {}, 0, nil
    end
    
    local file, err = io.open(filepath, "r")
    if not file then
        return nil, 0, "无法打开文件进行读取: " .. (err or "未知错误")
    end
    
    local students = {}
    local count = 0
    local errors = {}
    local line_num = 0
    
    for line in file:lines() do
        line_num = line_num + 1
        line = utils.trim(line)
        
        if line ~= "" and not line:match("^#") then
            local stu, parse_err = student.deserialize(line)
            if stu then
                students[stu.id] = stu
                count = count + 1
            else
                table.insert(errors, string.format("第 %d 行: %s", line_num, parse_err or "解析失败"))
            end
        end
    end
    
    file:close()
    
    if #errors > 0 then
        return students, count, table.concat(errors, "\n")
    end
    
    return students, count, nil
end

-----------------------------------------------------------
-- 备份与恢复
-----------------------------------------------------------

function storage.backup(filename)
    local filepath = storage.get_filepath(filename)
    
    if not storage.file_exists(filepath) then
        return false, "源文件不存在"
    end
    
    local backup_path = filepath .. ".backup." .. os.date("%Y%m%d%H%M%S")
    
    local src = io.open(filepath, "r")
    if not src then
        return false, "无法读取源文件"
    end
    
    local dst = io.open(backup_path, "w")
    if not dst then
        src:close()
        return false, "无法创建备份文件"
    end
    
    local content = src:read("*a")
    dst:write(content)
    
    src:close()
    dst:close()
    
    return true, backup_path
end

-----------------------------------------------------------
-- 导出功能
-----------------------------------------------------------

function storage.export_csv(students, filename)
    filename = filename or "students_export.csv"
    
    local file, err = io.open(filename, "w")
    if not file then
        return false, "无法创建导出文件: " .. (err or "未知错误")
    end
    
    local all_subjects = {}
    local subject_set = {}
    
    for _, stu in pairs(students) do
        for subj, _ in pairs(stu.scores) do
            if not subject_set[subj] then
                subject_set[subj] = true
                table.insert(all_subjects, subj)
            end
        end
    end
    table.sort(all_subjects)
    
    local header = "学号,姓名,班级"
    for _, subj in ipairs(all_subjects) do
        header = header .. "," .. subj
    end
    header = header .. ",总分,平均分"
    file:write(header .. "\n")
    
    local sorted_ids = {}
    for id, _ in pairs(students) do
        table.insert(sorted_ids, id)
    end
    table.sort(sorted_ids)
    
    for _, id in ipairs(sorted_ids) do
        local stu = students[id]
        local row = string.format("%s,%s,%s", stu.id, stu.name, stu.class_name)
        
        for _, subj in ipairs(all_subjects) do
            local score = stu.scores[subj]
            if score then
                row = row .. "," .. tostring(score)
            else
                row = row .. ","
            end
        end
        
        row = row .. "," .. tostring(student.get_total_score(stu))
        row = row .. "," .. tostring(student.get_average_score(stu))
        
        file:write(row .. "\n")
    end
    
    file:close()
    return true, filename
end

return storage