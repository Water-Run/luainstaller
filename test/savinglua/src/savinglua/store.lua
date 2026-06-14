--[[
SQLite-backed table record store for the savinglua packaging sample.

Author:
    WaterRun
File:
    store.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local cjson = require("cjson")
local sqlite3 = require("lsqlite3")

local Store = {}
Store.__index = Store

local function check_sqlite(code, db, message)
    if code ~= sqlite3.OK and code ~= sqlite3.DONE and code ~= sqlite3.ROW then
        return nil, (message or "sqlite error") .. ": " .. tostring(db:errmsg())
    end
    return true
end

local function bind_and_step(stmt, db, ...)
    local ok, err = stmt:bind_values(...)
    if ok ~= sqlite3.OK then
        stmt:finalize()
        return nil, "bind failed: " .. tostring(db:errmsg())
    end
    local step = stmt:step()
    stmt:finalize()
    return check_sqlite(step, db, "statement failed")
end

function Store.open(path)
    if not path or path == "" then
        return nil, "database path is required"
    end

    local db, err = sqlite3.open(path)
    if not db then
        return nil, err or "failed to open database"
    end

    local schema = [[
        CREATE TABLE IF NOT EXISTS records (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        );
    ]]
    local ok, exec_err = db:exec(schema)
    if ok ~= sqlite3.OK then
        local message = exec_err or db:errmsg()
        db:close()
        return nil, "failed to initialize schema: " .. tostring(message)
    end

    return setmetatable({ db = db }, Store)
end

function Store:put(key, value)
    if not key or key == "" then
        return nil, "key is required"
    end
    if type(value) ~= "table" then
        return nil, "value must be a table"
    end

    local stmt = assert(self.db:prepare([[
        INSERT INTO records(key, value, updated_at)
        VALUES(?, ?, strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at;
    ]]))
    return bind_and_step(stmt, self.db, key, cjson.encode(value))
end

function Store:get(key)
    if not key or key == "" then
        return nil, "key is required"
    end

    local stmt = assert(self.db:prepare("SELECT value FROM records WHERE key = ?"))
    assert(stmt:bind_values(key) == sqlite3.OK)
    local step = stmt:step()
    if step == sqlite3.ROW then
        local value = stmt:get_value(0)
        stmt:finalize()
        return cjson.decode(value)
    end
    stmt:finalize()
    if step == sqlite3.DONE then
        return nil
    end
    return nil, self.db:errmsg()
end

function Store:scan(prefix)
    prefix = prefix or ""
    local stmt = assert(self.db:prepare([[
        SELECT key, value, updated_at
        FROM records
        WHERE key LIKE ?
        ORDER BY key ASC;
    ]]))
    assert(stmt:bind_values(prefix .. "%") == sqlite3.OK)

    local rows = {}
    while stmt:step() == sqlite3.ROW do
        rows[#rows + 1] = {
            key = stmt:get_value(0),
            value = cjson.decode(stmt:get_value(1)),
            updated_at = tonumber(stmt:get_value(2)),
        }
    end
    stmt:finalize()
    return rows
end

function Store:delete(key)
    if not key or key == "" then
        return nil, "key is required"
    end
    local stmt = assert(self.db:prepare("DELETE FROM records WHERE key = ?"))
    return bind_and_step(stmt, self.db, key)
end

function Store:close()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

return Store
