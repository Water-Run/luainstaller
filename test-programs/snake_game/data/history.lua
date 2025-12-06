--[[
    History module - Score persistence and statistics
]]

local history = {}

-- File path for history data
local HISTORY_FILE = "snake_history.dat"

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

-- Serialize table to string (simple implementation)
local function serialize(tbl)
    local parts = {}

    for key, value in pairs(tbl) do
        local key_str = tostring(key)
        local value_str

        if type(value) == "table" then
            value_str = serialize(value)
        elseif type(value) == "string" then
            value_str = string.format("%q", value)
        else
            value_str = tostring(value)
        end

        table.insert(parts, string.format("[%q]=%s", key_str, value_str))
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

-- Deserialize string to table (simple implementation)
local function deserialize(str)
    local func = load("return " .. str)
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

    return stats
end

-- Save history to file
function history.save(stats)
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
