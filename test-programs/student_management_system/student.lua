-- student.lua
-- 学生对象模块
-- 定义学生数据结构和相关操作

local utils = require("utils")

local student = {}

-----------------------------------------------------------
-- 学生对象构造
-----------------------------------------------------------

function student.new(id, name, class_name)
    return {
        id = id,
        name = name,
        class_name = class_name or "未分班",
        scores = {},
        created_at = utils.get_timestamp(),
        updated_at = utils.get_timestamp()
    }
end

function student.validate(stu)
    if type(stu) ~= "table" then
        return false, "无效的学生数据"
    end
    if not stu.id or utils.trim(tostring(stu.id)) == "" then
        return false, "学号不能为空"
    end
    if not stu.name or utils.trim(stu.name) == "" then
        return false, "姓名不能为空"
    end
    return true, nil
end

-----------------------------------------------------------
-- 成绩操作
-----------------------------------------------------------

function student.set_score(stu, subject, score)
    if not utils.is_valid_score(score) then
        return false, "成绩必须在 0-100 之间"
    end
    stu.scores[subject] = tonumber(score)
    stu.updated_at = utils.get_timestamp()
    return true, nil
end

function student.get_score(stu, subject)
    return stu.scores[subject]
end

function student.remove_score(stu, subject)
    if stu.scores[subject] then
        stu.scores[subject] = nil
        stu.updated_at = utils.get_timestamp()
        return true
    end
    return false
end

function student.get_subjects(stu)
    return utils.table_keys(stu.scores)
end

-----------------------------------------------------------
-- 统计计算
-----------------------------------------------------------

function student.get_total_score(stu)
    local total = 0
    for _, score in pairs(stu.scores) do
        total = total + score
    end
    return total
end

function student.get_average_score(stu)
    local total = 0
    local count = 0
    for _, score in pairs(stu.scores) do
        total = total + score
        count = count + 1
    end
    if count == 0 then
        return 0
    end
    return utils.round(total / count, 2)
end

function student.get_subject_count(stu)
    local count = 0
    for _ in pairs(stu.scores) do
        count = count + 1
    end
    return count
end

function student.get_highest_score(stu)
    local highest = nil
    local subject = nil
    for subj, score in pairs(stu.scores) do
        if highest == nil or score > highest then
            highest = score
            subject = subj
        end
    end
    return highest, subject
end

function student.get_lowest_score(stu)
    local lowest = nil
    local subject = nil
    for subj, score in pairs(stu.scores) do
        if lowest == nil or score < lowest then
            lowest = score
            subject = subj
        end
    end
    return lowest, subject
end

-----------------------------------------------------------
-- 格式化输出
-----------------------------------------------------------

function student.to_string(stu)
    local avg = student.get_average_score(stu)
    local total = student.get_total_score(stu)
    local count = student.get_subject_count(stu)
    return string.format(
        "学号: %s | 姓名: %s | 班级: %s | 科目数: %d | 总分: %.1f | 平均分: %.2f",
        stu.id, stu.name, stu.class_name, count, total, avg
    )
end

function student.print_detail(stu)
    utils.print_line("-")
    print(string.format("学号: %s", stu.id))
    print(string.format("姓名: %s", stu.name))
    print(string.format("班级: %s", stu.class_name))
    print(string.format("创建时间: %s", stu.created_at))
    print(string.format("更新时间: %s", stu.updated_at))
    utils.print_line("-")
    
    local subjects = student.get_subjects(stu)
    if #subjects == 0 then
        print("  (暂无成绩记录)")
    else
        print("成绩列表:")
        for _, subj in ipairs(subjects) do
            print(string.format("  %-10s : %.1f", subj, stu.scores[subj]))
        end
        utils.print_line("-")
        print(string.format("总分: %.1f", student.get_total_score(stu)))
        print(string.format("平均分: %.2f", student.get_average_score(stu)))
        
        local highest, h_subj = student.get_highest_score(stu)
        local lowest, l_subj = student.get_lowest_score(stu)
        if highest then
            print(string.format("最高分: %.1f (%s)", highest, h_subj))
        end
        if lowest then
            print(string.format("最低分: %.1f (%s)", lowest, l_subj))
        end
    end
    utils.print_line("-")
end

-----------------------------------------------------------
-- 序列化
-----------------------------------------------------------

function student.serialize(stu)
    local scores_parts = {}
    for subj, score in pairs(stu.scores) do
        table.insert(scores_parts, subj .. ":" .. tostring(score))
    end
    local scores_str = table.concat(scores_parts, ";")
    
    return string.format("%s|%s|%s|%s|%s|%s",
        stu.id,
        stu.name,
        stu.class_name,
        scores_str,
        stu.created_at,
        stu.updated_at
    )
end

function student.deserialize(line)
    local parts = {}
    for part in line:gmatch("([^|]+)") do
        table.insert(parts, part)
    end
    
    if #parts < 6 then
        return nil, "数据格式错误"
    end
    
    local stu = {
        id = parts[1],
        name = parts[2],
        class_name = parts[3],
        scores = {},
        created_at = parts[5],
        updated_at = parts[6]
    }
    
    local scores_str = parts[4]
    if scores_str and scores_str ~= "" then
        for pair in scores_str:gmatch("([^;]+)") do
            local subj, score = pair:match("([^:]+):([^:]+)")
            if subj and score then
                stu.scores[subj] = tonumber(score)
            end
        end
    end
    
    return stu, nil
end

return student