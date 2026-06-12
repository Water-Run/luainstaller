--[[
Database adapter for the Firebird Web SQL Shell sample.

Author:
    WaterRun
File:
    db.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local M = {}

local MOCK_TABLES = {
    DEPARTMENT = {
        columns = {
            { name = "ID", type = "INTEGER" },
            { name = "NAME", type = "VARCHAR(80)" },
        },
        rows = {
            { ID = 1, NAME = "Engineering" },
            { ID = 2, NAME = "Finance" },
            { ID = 3, NAME = "Support" },
        },
    },
    EMPLOYEE = {
        columns = {
            { name = "ID", type = "INTEGER" },
            { name = "NAME", type = "VARCHAR(120)" },
            { name = "DEPARTMENT_ID", type = "INTEGER" },
            { name = "SALARY", type = "NUMERIC(12,2)" },
        },
        rows = {
            { ID = 1, NAME = "Ada Lovelace", DEPARTMENT_ID = 1, SALARY = 125000 },
            { ID = 2, NAME = "Grace Hopper", DEPARTMENT_ID = 1, SALARY = 121000 },
            { ID = 3, NAME = "Alan Turing", DEPARTMENT_ID = 2, SALARY = 118500 },
            { ID = 4, NAME = "Barbara Liskov", DEPARTMENT_ID = 3, SALARY = 116000 },
        },
    },
}

local Connection = {}
Connection.__index = Connection

local function trim(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function upper(value)
    return trim(value):upper()
end

local function csv_escape(value)
    local text = tostring(value == nil and "" or value)
    if text:find('[,"\n\r]') then
        text = '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

local function columns_from_rows(rows)
    local seen = {}
    local columns = {}
    for _, row in ipairs(rows) do
        for key in pairs(row) do
            if not seen[key] then
                seen[key] = true
                columns[#columns + 1] = key
            end
        end
    end
    table.sort(columns)
    return columns
end

local function project_rows(rows, selected_columns, max_rows)
    local out = {}
    for i = 1, math.min(#rows, max_rows) do
        local source = rows[i]
        local row = {}
        for _, column in ipairs(selected_columns) do
            row[column] = source[column]
        end
        out[#out + 1] = row
    end
    return out
end

local function mock_select(sql, max_rows)
    local count_table = sql:match("^%s*select%s+count%s*%(%s*%*%s*%)%s+from%s+([%w_]+)")
    if count_table then
        local table_def = MOCK_TABLES[upper(count_table)]
        if not table_def then
            return nil, "unknown table: " .. count_table
        end
        return {
            kind = "select",
            columns = { "COUNT" },
            rows = { { COUNT = #table_def.rows } },
            row_count = 1,
            truncated = false,
            summary = "1 row",
        }
    end

    local select_part, table_name = sql:match("^%s*select%s+(.+)%s+from%s+([%w_]+)")
    if not table_name then
        return nil, "mock driver supports SELECT ... FROM <table>"
    end
    local table_def = MOCK_TABLES[upper(table_name)]
    if not table_def then
        return nil, "unknown table: " .. table_name
    end

    local selected_columns = {}
    if trim(select_part) == "*" then
        for _, column in ipairs(table_def.columns) do
            selected_columns[#selected_columns + 1] = column.name
        end
    else
        for column in select_part:gmatch("[^,]+") do
            selected_columns[#selected_columns + 1] = upper(column)
        end
    end

    local rows = project_rows(table_def.rows, selected_columns, max_rows)
    return {
        kind = "select",
        columns = selected_columns,
        rows = rows,
        row_count = #rows,
        truncated = #table_def.rows > max_rows,
        summary = string.format("%d row(s)", #rows),
    }
end

local function load_luasql_firebird()
    local loader = _G.require
    local ok, luasql = pcall(loader, "luasql.firebird")
    if ok then
        return luasql
    end
    return nil, luasql
end

function Connection:connect()
    if self.driver == "mock" then
        self.connected = true
        return true
    end

    local luasql, err = load_luasql_firebird()
    if not luasql then
        return false, "luasql.firebird not available: " .. tostring(err)
    end

    local env = luasql.firebird()
    local fb = self.firebird or {}
    local database = fb.database or ""
    if database == "" then
        return false, "Firebird database path is required"
    end

    local conn, connect_err = env:connect(database, fb.user, fb.password, fb.host, fb.role, fb.charset)
    if not conn then
        return false, tostring(connect_err)
    end

    self.env = env
    self.conn = conn
    self.connected = true
    return true
end

function Connection:close()
    if self.conn and self.conn.close then
        pcall(self.conn.close, self.conn)
    end
    if self.env and self.env.close then
        pcall(self.env.close, self.env)
    end
    self.conn = nil
    self.env = nil
    self.connected = false
end

function Connection:status()
    local fb = self.firebird or {}
    return {
        driver = self.driver,
        connected = self.connected == true,
        database = self.driver == "mock" and "mock.fdb" or fb.database,
        host = self.driver == "mock" and "local" or fb.host,
    }
end

function Connection:query(sql, opts)
    opts = opts or {}
    sql = trim(sql)
    local max_rows = tonumber(opts.max_rows) or self.max_rows or 500
    if sql == "" then
        return nil, "SQL is empty"
    end
    if not self.connected then
        local ok, err = self:connect()
        if not ok then
            return nil, err
        end
    end

    if self.driver == "mock" then
        if sql:lower():match("^%s*select") then
            return mock_select(sql, max_rows)
        end
        return {
            kind = "execute",
            columns = {},
            rows = {},
            affected_rows = 1,
            row_count = 0,
            truncated = false,
            summary = "mock statement executed",
        }
    end

    local cursor_or_count, err = self.conn:execute(sql)
    if not cursor_or_count then
        return nil, tostring(err)
    end
    if type(cursor_or_count) == "number" then
        return {
            kind = "execute",
            columns = {},
            rows = {},
            affected_rows = cursor_or_count,
            row_count = 0,
            truncated = false,
            summary = tostring(cursor_or_count) .. " affected",
        }
    end

    local cursor = cursor_or_count
    local rows = {}
    local columns = {}
    if cursor.getcolnames then
        columns = cursor:getcolnames()
    end
    while #rows < max_rows do
        local row = cursor:fetch({}, "a")
        if not row then
            break
        end
        if #columns == 0 then
            columns = columns_from_rows({ row })
        end
        rows[#rows + 1] = row
    end
    cursor:close()

    return {
        kind = "select",
        columns = columns,
        rows = rows,
        row_count = #rows,
        truncated = #rows >= max_rows,
        summary = string.format("%d row(s)", #rows),
    }
end

function Connection:tables()
    if self.driver == "mock" then
        local out = {}
        for name, def in pairs(MOCK_TABLES) do
            out[#out + 1] = {
                name = name,
                type = "TABLE",
                columns = #def.columns,
                rows = #def.rows,
            }
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end
    return self:query([[
select rdb$relation_name as name
from rdb$relations
where rdb$view_blr is null and (rdb$system_flag is null or rdb$system_flag = 0)
order by rdb$relation_name
]])
end

function Connection:table_info(name)
    name = upper(name)
    if self.driver == "mock" then
        local def = MOCK_TABLES[name]
        if not def then
            return nil, "unknown table: " .. name
        end
        return {
            name = name,
            columns = def.columns,
            sample = project_rows(def.rows, columns_from_rows(def.rows), 20),
        }
    end
    local escaped = name:gsub("'", "''")
    return self:query(string.format([[
select rf.rdb$field_name as name, f.rdb$field_type as type_code
from rdb$relation_fields rf
join rdb$fields f on f.rdb$field_name = rf.rdb$field_source
where rf.rdb$relation_name = '%s'
order by rf.rdb$field_position
]], escaped))
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        driver = opts.driver or "mock",
        max_rows = tonumber(opts.max_rows) or 500,
        firebird = opts.firebird or {},
        connected = false,
    }, Connection)
end

function M.to_csv(columns, rows)
    local lines = {}
    local header = {}
    for _, column in ipairs(columns or {}) do
        header[#header + 1] = csv_escape(column)
    end
    lines[#lines + 1] = table.concat(header, ",")
    for _, row in ipairs(rows or {}) do
        local cells = {}
        for _, column in ipairs(columns or {}) do
            cells[#cells + 1] = csv_escape(row[column])
        end
        lines[#lines + 1] = table.concat(cells, ",")
    end
    return table.concat(lines, "\n") .. "\n"
end

return M
