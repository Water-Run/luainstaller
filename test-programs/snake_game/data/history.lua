--[[
    History module - Score persistence and statistics
]]

local history = {}

-- File path for history data (相对于游戏目录)
local HISTORY_FILE = "data/snake_history.dat"

-- Default stats structure
local function default_stats()
    return {
        high_score = 0,
        games_played = 0,
        total_score = 0,
        last_played = "",
        score_history = {}
    }
end

-- Serialize table to string
local function serialize(tbl, indent)
    indent = indent or ""
    local parts = {}
    local next_indent = indent .. "  "

    for key, value in pairs(tbl) do
        local key_str
        if type(key) == "number" then
            key_str = "[" .. key .. "]"
        else
            key_str = "[" .. string.format("%q", tostring(key)) .. "]"
        end

        local value_str
        if type(value) == "table" then
            value_str = serialize(value, next_indent)
        elseif type(value) == "string" then
            value_str = string.format("%q", value)
        elseif type(value) == "number" then
            value_str = tostring(value)
        elseif type(value) == "boolean" then
            value_str = tostring(value)
        else
            value_str = "nil"
        end

        table.insert(parts, key_str .. " = " .. value_str)
    end

    if #parts == 0 then
        return "{}"
    end

    return "{\n" .. next_indent .. table.concat(parts, ",\n" .. next_indent) .. "\n" .. indent .. "}"
end

-- Deserialize string to table (安全实现)
local function deserialize(str)
    -- 使用 load 函数解析，但在沙盒环境中执行
    local func, err = load("return " .. str, "data", "t", {})
    if func then
        local ok, result = pcall(func)
        if ok and type(result) == "table" then
            return result
        end
    end
    return nil
end

-- Load history from file
function history.load()
    local file = io.open(HISTORY_FILE, "r")
    if not file then
        return default_stats()
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return default_stats()
    end

    local stats = deserialize(content)
    if not stats then
        return default_stats()
    end

    -- Ensure all fields exist
    local defaults = default_stats()
    for key, value in pairs(defaults) do
        if stats[key] == nil then
            stats[key] = value
        end
    end

    -- 确保 score_history 是表
    if type(stats.score_history) ~= "table" then
        stats.score_history = {}
    end

    return stats
end

-- Save history to file
function history.save(stats)
    -- 确保 data 目录存在
    os.execute("mkdir -p data 2>/dev/null || mkdir data 2>nul")

    local file = io.open(HISTORY_FILE, "w")
    if not file then
        return false
    end

    file:write(serialize(stats))
    file:close()
    return true
end

-- Update stats with new game result
function history.update(score)
    local stats = history.load()

    stats.games_played = stats.games_played + 1
    stats.total_score = stats.total_score + score
    stats.last_played = os.date("%Y-%m-%d %H:%M:%S")

    if score > stats.high_score then
        stats.high_score = score
    end

    -- Keep last 10 scores
    table.insert(stats.score_history, 1, {
        score = score,
        date = stats.last_played
    })

    while #stats.score_history > 10 do
        table.remove(stats.score_history)
    end

    return stats
end

-- Get average score
function history.get_average(stats)
    if stats.games_played == 0 then
        return 0
    end
    return stats.total_score / stats.games_played
end

-- Get recent scores
function history.get_recent(stats, count)
    count = count or 5
    local recent = {}

    for i = 1, math.min(count, #stats.score_history) do
        table.insert(recent, stats.score_history[i])
    end

    return recent
end

-- Clear all history
function history.clear()
    local stats = default_stats()
    history.save(stats)
    return stats
end

return history