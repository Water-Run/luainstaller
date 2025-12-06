-- main.lua
-- 学生成绩管理系统 - 入口脚本
-- 支持增删改查学生信息、成绩录入、统计分析

local utils = require("utils")
local student = require("student")
local storage = require("storage")

-----------------------------------------------------------
-- 全局状态
-----------------------------------------------------------

local students = {}
local data_file = "students.dat"
local modified = false

-----------------------------------------------------------
-- 初始化
-----------------------------------------------------------

local function init()
    print()
    utils.print_header("学生成绩管理系统 v1.0")
    print()
    
    local data, count, err = storage.load(data_file)
    if err then
        print("警告: 加载数据时出现错误:")
        print(err)
    end
    
    if data then
        students = data
        print(string.format("已加载 %d 条学生记录", count))
    else
        students = {}
        print("未找到数据文件，将创建新的数据库")
    end
    print()
end

-----------------------------------------------------------
-- 保存数据
-----------------------------------------------------------

local function save_data()
    local success, result = storage.save(students, data_file)
    if success then
        modified = false
        print(string.format("✓ 已保存 %d 条记录到 %s", result, data_file))
    else
        print("✗ 保存失败: " .. result)
    end
end

local function check_save_before_exit()
    if modified then
        if utils.confirm("数据已修改，是否保存?") then
            save_data()
        end
    end
end

-----------------------------------------------------------
-- 学生管理功能
-----------------------------------------------------------

local function add_student()
    utils.print_header("添加学生")
    
    local id = utils.prompt("请输入学号: ")
    if not id or id == "" then
        print("取消添加")
        return
    end
    
    if students[id] then
        print("✗ 学号已存在!")
        return
    end
    
    local name = utils.prompt("请输入姓名: ")
    if not name or name == "" then
        print("取消添加")
        return
    end
    
    local class_name = utils.prompt("请输入班级 (可选): ")
    if class_name == "" then
        class_name = "未分班"
    end
    
    local stu = student.new(id, name, class_name)
    students[id] = stu
    modified = true
    
    print()
    print("✓ 学生添加成功!")
    student.print_detail(stu)
end

local function delete_student()
    utils.print_header("删除学生")
    
    local id = utils.prompt("请输入要删除的学号: ")
    if not id or id == "" then
        print("取消操作")
        return
    end
    
    local stu = students[id]
    if not stu then
        print("✗ 未找到该学生!")
        return
    end
    
    print()
    print("即将删除以下学生:")
    print(student.to_string(stu))
    print()
    
    if utils.confirm("确认删除?") then
        students[id] = nil
        modified = true
        print("✓ 删除成功!")
    else
        print("取消删除")
    end
end

local function find_student()
    utils.print_header("查找学生")
    
    local keyword = utils.prompt("请输入学号或姓名: ")
    if not keyword or keyword == "" then
        print("取消查找")
        return
    end
    
    local found = {}
    keyword = keyword:lower()
    
    for id, stu in pairs(students) do
        if id:lower():find(keyword, 1, true) or 
           stu.name:lower():find(keyword, 1, true) then
            table.insert(found, stu)
        end
    end
    
    print()
    if #found == 0 then
        print("未找到匹配的学生")
    else
        print(string.format("找到 %d 条记录:", #found))
        for _, stu in ipairs(found) do
            print()
            student.print_detail(stu)
        end
    end
end

local function modify_student()
    utils.print_header("修改学生信息")
    
    local id = utils.prompt("请输入学号: ")
    if not id or id == "" then
        print("取消操作")
        return
    end
    
    local stu = students[id]
    if not stu then
        print("✗ 未找到该学生!")
        return
    end
    
    print()
    print("当前信息:")
    student.print_detail(stu)
    
    print()
    print("请输入新信息 (直接回车保持不变):")
    
    local new_name = utils.prompt(string.format("姓名 [%s]: ", stu.name))
    if new_name ~= "" then
        stu.name = new_name
        stu.updated_at = utils.get_timestamp()
        modified = true
    end
    
    local new_class = utils.prompt(string.format("班级 [%s]: ", stu.class_name))
    if new_class ~= "" then
        stu.class_name = new_class
        stu.updated_at = utils.get_timestamp()
        modified = true
    end
    
    print()
    print("✓ 修改完成!")
    student.print_detail(stu)
end

local function list_students()
    utils.print_header("学生列表")
    
    local count = 0
    local sorted_ids = {}
    
    for id, _ in pairs(students) do
        table.insert(sorted_ids, id)
        count = count + 1
    end
    
    if count == 0 then
        print("暂无学生记录")
        return
    end
    
    table.sort(sorted_ids)
    
    print(string.format("共 %d 名学生:", count))
    utils.print_line("-")
    
    for i, id in ipairs(sorted_ids) do
        local stu = students[id]
        print(string.format("%d. %s", i, student.to_string(stu)))
    end
    
    utils.print_line("-")
end

-----------------------------------------------------------
-- 成绩管理功能
-----------------------------------------------------------

local function input_scores()
    utils.print_header("录入成绩")
    
    local id = utils.prompt("请输入学号: ")
    if not id or id == "" then
        print("取消操作")
        return
    end
    
    local stu = students[id]
    if not stu then
        print("✗ 未找到该学生!")
        return
    end
    
    print()
    print(string.format("正在为 %s (%s) 录入成绩", stu.name, stu.id))
    print("输入格式: 科目名 分数 (如: 数学 95)")
    print("输入 'done' 结束录入")
    print()
    
    while true do
        local input = utils.prompt("> ")
        if not input or input:lower() == "done" then
            break
        end
        
        local subject, score = input:match("^(%S+)%s+(%S+)$")
        if not subject or not score then
            print("  格式错误，请使用: 科目名 分数")
        else
            local success, err = student.set_score(stu, subject, score)
            if success then
                print(string.format("  ✓ %s: %.1f", subject, tonumber(score)))
                modified = true
            else
                print("  ✗ " .. err)
            end
        end
    end
    
    print()
    print("录入完成!")
    student.print_detail(stu)
end

local function view_scores()
    utils.print_header("查看成绩")
    
    local id = utils.prompt("请输入学号: ")
    if not id or id == "" then
        print("取消操作")
        return
    end
    
    local stu = students[id]
    if not stu then
        print("✗ 未找到该学生!")
        return
    end
    
    print()
    student.print_detail(stu)
end

local function delete_score()
    utils.print_header("删除成绩")
    
    local id = utils.prompt("请输入学号: ")
    if not id or id == "" then
        print("取消操作")
        return
    end
    
    local stu = students[id]
    if not stu then
        print("✗ 未找到该学生!")
        return
    end
    
    local subjects = student.get_subjects(stu)
    if #subjects == 0 then
        print("该学生暂无成绩记录")
        return
    end
    
    print()
    print("当前成绩:")
    for i, subj in ipairs(subjects) do
        print(string.format("  %d. %s: %.1f", i, subj, stu.scores[subj]))
    end
    print()
    
    local subject = utils.prompt("请输入要删除的科目: ")
    if not subject or subject == "" then
        print("取消操作")
        return
    end
    
    if student.remove_score(stu, subject) then
        modified = true
        print("✓ 成绩已删除")
    else
        print("✗ 未找到该科目")
    end
end

-----------------------------------------------------------
-- 统计分析功能
-----------------------------------------------------------

local function statistics()
    utils.print_header("统计分析")
    
    local count = 0
    local total_avg = 0
    local class_stats = {}
    local subject_stats = {}
    
    for _, stu in pairs(students) do
        count = count + 1
        total_avg = total_avg + student.get_average_score(stu)
        
        local cls = stu.class_name
        if not class_stats[cls] then
            class_stats[cls] = {count = 0, total = 0}
        end
        class_stats[cls].count = class_stats[cls].count + 1
        class_stats[cls].total = class_stats[cls].total + student.get_average_score(stu)
        
        for subj, score in pairs(stu.scores) do
            if not subject_stats[subj] then
                subject_stats[subj] = {count = 0, total = 0, max = score, min = score}
            end
            local ss = subject_stats[subj]
            ss.count = ss.count + 1
            ss.total = ss.total + score
            if score > ss.max then ss.max = score end
            if score < ss.min then ss.min = score end
        end
    end
    
    if count == 0 then
        print("暂无数据")
        return
    end
    
    print(string.format("学生总数: %d", count))
    print(string.format("全校平均分: %.2f", total_avg / count))
    
    print()
    print("班级统计:")
    utils.print_line("-", 40)
    for cls, stats in pairs(class_stats) do
        local avg = stats.total / stats.count
        print(string.format("  %s: %d 人, 平均分 %.2f", cls, stats.count, avg))
    end
    
    print()
    print("科目统计:")
    utils.print_line("-", 40)
    for subj, stats in pairs(subject_stats) do
        local avg = stats.total / stats.count
        print(string.format("  %s: 参考 %d 人, 平均 %.2f, 最高 %.1f, 最低 %.1f",
            subj, stats.count, avg, stats.max, stats.min))
    end
    
    utils.print_line("-", 40)
end

local function ranking()
    utils.print_header("成绩排名")
    
    local list = {}
    for _, stu in pairs(students) do
        table.insert(list, {
            id = stu.id,
            name = stu.name,
            class_name = stu.class_name,
            avg = student.get_average_score(stu),
            total = student.get_total_score(stu)
        })
    end
    
    if #list == 0 then
        print("暂无数据")
        return
    end
    
    table.sort(list, function(a, b)
        return a.avg > b.avg
    end)
    
    print("按平均分排名:")
    utils.print_line("-")
    print(string.format("%-4s %-10s %-10s %-10s %-8s %-8s",
        "排名", "学号", "姓名", "班级", "总分", "平均分"))
    utils.print_line("-")
    
    for i, item in ipairs(list) do
        print(string.format("%-4d %-10s %-10s %-10s %-8.1f %-8.2f",
            i, item.id, item.name, item.class_name, item.total, item.avg))
    end
    
    utils.print_line("-")
end

-----------------------------------------------------------
-- 数据管理功能
-----------------------------------------------------------

local function backup_data()
    utils.print_header("备份数据")
    
    local success, result = storage.backup(data_file)
    if success then
        print("✓ 备份成功: " .. result)
    else
        print("✗ 备份失败: " .. result)
    end
end

local function export_data()
    utils.print_header("导出数据")
    
    local filename = utils.prompt("请输入导出文件名 (默认: students_export.csv): ")
    if filename == "" then
        filename = nil
    end
    
    local success, result = storage.export_csv(students, filename)
    if success then
        print("✓ 导出成功: " .. result)
    else
        print("✗ 导出失败: " .. result)
    end
end

-----------------------------------------------------------
-- 主菜单
-----------------------------------------------------------

local function print_menu()
    print()
    utils.print_line("=")
    print("  主菜单")
    utils.print_line("=")
    print("  [学生管理]")
    print("    1. 添加学生")
    print("    2. 删除学生")
    print("    3. 查找学生")
    print("    4. 修改学生")
    print("    5. 学生列表")
    print()
    print("  [成绩管理]")
    print("    6. 录入成绩")
    print("    7. 查看成绩")
    print("    8. 删除成绩")
    print()
    print("  [统计分析]")
    print("    9. 统计分析")
    print("   10. 成绩排名")
    print()
    print("  [数据管理]")
    print("   11. 保存数据")
    print("   12. 备份数据")
    print("   13. 导出CSV")
    print()
    print("    0. 退出系统")
    utils.print_line("=")
end

local function main_loop()
    local handlers = {
        ["1"] = add_student,
        ["2"] = delete_student,
        ["3"] = find_student,
        ["4"] = modify_student,
        ["5"] = list_students,
        ["6"] = input_scores,
        ["7"] = view_scores,
        ["8"] = delete_score,
        ["9"] = statistics,
        ["10"] = ranking,
        ["11"] = save_data,
        ["12"] = backup_data,
        ["13"] = export_data,
    }
    
    while true do
        print_menu()
        
        local choice = utils.prompt("请选择操作: ")
        
        if choice == "0" or choice == nil then
            check_save_before_exit()
            print()
            print("感谢使用，再见!")
            print()
            break
        end
        
        local handler = handlers[choice]
        if handler then
            print()
            handler()
        else
            print("无效的选择，请重新输入")
        end
    end
end

-----------------------------------------------------------
-- 程序入口
-----------------------------------------------------------

init()
main_loop()