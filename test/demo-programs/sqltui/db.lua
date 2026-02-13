local sqlite3 = require("lsqlite3")

local DB = {}
DB.__index = DB

function DB.new()
    return setmetatable({ db = nil, path = nil, intx = false }, DB)
end

function DB:open(path)
    if self.db then self:close() end
    local d, _, msg = sqlite3.open(path)
    if not d then return false, msg or "cannot open" end
    self.db, self.path, self.intx = d, path, false
    return true
end

function DB:close()
    if not self.db then return end
    if self.intx then pcall(function() self.db:exec("ROLLBACK") end) end
    self.db:close()
    self.db, self.path, self.intx = nil, nil, false
end

function DB:exec(sql)
    if not self.db then return nil, "no database" end
    local stmt = self.db:prepare(sql)
    if not stmt then return nil, self.db:errmsg() end
    local ncols = stmt:columns()
    if ncols == 0 then
        stmt:finalize()
        local rc = self.db:exec(sql)
        if rc ~= sqlite3.OK then return nil, self.db:errmsg() end
        return { message = ("OK (%d changes)"):format(self.db:changes()) }
    end
    local cols = stmt:get_names()
    local rows = {}
    while stmt:step() == sqlite3.ROW do
        local vals = stmt:get_values()
        local row = {}
        for i = 1, ncols do
            row[i] = vals[i] == nil and "NULL" or tostring(vals[i]):gsub("%c", " ")
        end
        rows[#rows + 1] = row
    end
    stmt:finalize()
    return { cols = cols, rows = rows }
end

function DB:tables()
    return self:exec("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
end

function DB:schema(name)
    return self:exec(("SELECT sql FROM sqlite_master WHERE name='%s'"):format(name:gsub("'", "''")))
end

function DB:indices(name)
    return self:exec(("SELECT name,sql FROM sqlite_master WHERE type='index' AND tbl_name='%s'"):format(name:gsub("'",
        "''")))
end

function DB:begin_tx()
    if not self.db then return false, "no database" end
    if self.intx then return false, "already in transaction" end
    if self.db:exec("BEGIN") ~= sqlite3.OK then return false, self.db:errmsg() end
    self.intx = true
    return true
end

function DB:commit()
    if not self.db then return false, "no database" end
    if not self.intx then return false, "no transaction" end
    if self.db:exec("COMMIT") ~= sqlite3.OK then return false, self.db:errmsg() end
    self.intx = false
    return true
end

function DB:rollback()
    if not self.db then return false, "no database" end
    if not self.intx then return false, "no transaction" end
    if self.db:exec("ROLLBACK") ~= sqlite3.OK then return false, self.db:errmsg() end
    self.intx = false
    return true
end

return DB
