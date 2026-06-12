--[[
In-memory SQL history for the Firebird Web SQL Shell sample.

Author:
    WaterRun
File:
    history.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local H = {}
H.__index = H

function H:add(sql, ok, summary)
    sql = tostring(sql or "")
    if sql:gsub("%s+", "") == "" then
        return
    end
    self.seq = self.seq + 1
    table.insert(self.items, 1, {
        id = self.seq,
        sql = sql,
        ok = ok == true,
        summary = tostring(summary or ""),
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    while #self.items > self.limit do
        table.remove(self.items)
    end
end

function H:list()
    local out = {}
    for i, item in ipairs(self.items) do
        out[i] = item
    end
    return out
end

function H:clear()
    self.items = {}
end

local M = {}

function M.new(limit)
    return setmetatable({
        limit = tonumber(limit) or 80,
        items = {},
        seq = 0,
    }, H)
end

return M
