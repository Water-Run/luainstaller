local ltui         = require("ltui")
local rect         = ltui.rect
local textdialog   = ltui.textdialog
local inputdialog  = ltui.inputdialog
local choicedialog = ltui.choicedialog

local UI           = {}

function UI.bounds(app, w, h)
    return rect { 0, 0, math.min(w, app:width() - 2), math.min(h, app:height() - 2) }
end

function UI.format(res)
    if res.message then return res.message end
    if not res.cols or #res.cols == 0 then return "(empty)" end
    local MW = 36
    local widths = {}
    for i, c in ipairs(res.cols) do widths[i] = #c end
    for _, row in ipairs(res.rows) do
        for i, v in ipairs(row) do
            if #v > widths[i] then widths[i] = #v end
        end
    end
    for i = 1, #widths do
        if widths[i] > MW then widths[i] = MW end
    end
    local function pad(s, n)
        if #s > n then return s:sub(1, n - 2) .. ".." end
        return s .. (" "):rep(n - #s)
    end
    local sep = "+"
    for _, w in ipairs(widths) do sep = sep .. ("-"):rep(w + 2) .. "+" end
    local hdr = "|"
    for i, c in ipairs(res.cols) do hdr = hdr .. " " .. pad(c, widths[i]) .. " |" end
    local lines = { sep, hdr, sep }
    for _, row in ipairs(res.rows) do
        local ln = "|"
        for i, v in ipairs(row) do ln = ln .. " " .. pad(v, widths[i]) .. " |" end
        lines[#lines + 1] = ln
    end
    lines[#lines + 1] = sep
    lines[#lines + 1] = ("(%d rows)"):format(#res.rows)
    return table.concat(lines, "\n")
end

function UI.msg(app, title, text)
    local d = textdialog:new("msg", UI.bounds(app, 60, 10), title)
    d:text():text_set(text)
    d:button_add("ok", "< OK >", function() app:remove(d) end)
    return d
end

function UI.result(app, res, err)
    local d = textdialog:new("result", UI.bounds(app, 78, 24), "Result")
    if err then
        d:text():text_set("ERROR: " .. err)
    elseif res then
        d:text():text_set(UI.format(res))
    else
        d:text():text_set("OK")
    end
    d:button_add("ok", "< OK >", function() app:remove(d) end)
    return d
end

function UI.input(app, title, prompt, on_ok)
    local d = inputdialog:new("input", UI.bounds(app, 64, 8), title)
    d:text():text_set(prompt)
    d:button_add("ok", "< OK >", function()
        local t = d:textedit():text()
        if t and #t > 0 then
            app:remove(d); on_ok(t)
        end
    end)
    d:button_add("cancel", "< Cancel >", function() app:remove(d) end)
    return d
end

function UI.workspace(app, db)
    local title = ("DB: %s%s"):format(db.path or "?", db.intx and " [TX]" or "")
    local d = choicedialog:new("workspace", UI.bounds(app, 60, 22), title)
    d:option_add("sql", "Execute SQL")
    d:option_add("tables", ".tables")
    d:option_add("schema", ".schema <table>")
    d:option_add("indices", ".indices <table>")
    d:option_add("pragma", "PRAGMA table_info")
    d:option_add("begin", "BEGIN Transaction")
    d:option_add("commit", "COMMIT")
    d:option_add("rollback", "ROLLBACK")
    d:option_add("vacuum", "VACUUM")
    d:option_add("close", "Close Database")
    local function refresh()
        app:remove(d)
        app:insert(UI.workspace(app, db))
    end
    d:button_add("go", "< Select >", function()
        local cur = d:option_current()
        if not cur then return end
        local n = cur.name
        if n == "sql" then
            app:insert(UI.input(app, "SQL", "Enter SQL:", function(s)
                local r, e = db:exec(s)
                app:insert(UI.result(app, r, e))
            end))
        elseif n == "tables" then
            local r, e = db:tables()
            app:insert(UI.result(app, r, e))
        elseif n == "schema" then
            app:insert(UI.input(app, ".schema", "Table name:", function(t)
                local r, e = db:schema(t)
                app:insert(UI.result(app, r, e))
            end))
        elseif n == "indices" then
            app:insert(UI.input(app, ".indices", "Table name:", function(t)
                local r, e = db:indices(t)
                app:insert(UI.result(app, r, e))
            end))
        elseif n == "pragma" then
            app:insert(UI.input(app, "PRAGMA", "Table name:", function(t)
                local r, e = db:exec("PRAGMA table_info(" .. t .. ")")
                app:insert(UI.result(app, r, e))
            end))
        elseif n == "begin" then
            local ok, e = db:begin_tx()
            if ok then refresh() else app:insert(UI.msg(app, "Error", e)) end
        elseif n == "commit" then
            local ok, e = db:commit()
            if ok then refresh() else app:insert(UI.msg(app, "Error", e)) end
        elseif n == "rollback" then
            local ok, e = db:rollback()
            if ok then refresh() else app:insert(UI.msg(app, "Error", e)) end
        elseif n == "vacuum" then
            local r, e = db:exec("VACUUM")
            app:insert(UI.result(app, r, e))
        elseif n == "close" then
            db:close()
            app:remove(d)
            app:insert(UI.main_menu(app, db))
        end
    end)
    return d
end

function UI.main_menu(app, db)
    local d = choicedialog:new("main", UI.bounds(app, 50, 12), "SQLite TUI")
    d:option_add("open", "Open Database")
    d:option_add("new", "New Database")
    d:option_add("quit", "Quit")
    d:button_add("go", "< Select >", function()
        local cur = d:option_current()
        if not cur then return end
        if cur.name == "quit" then
            app:quit()
        else
            app:insert(UI.input(app,
                cur.name == "new" and "New Database" or "Open Database",
                "File path:",
                function(path)
                    local ok, e = db:open(path)
                    if ok then
                        app:remove(d)
                        app:insert(UI.workspace(app, db))
                    else
                        app:insert(UI.msg(app, "Error", e))
                    end
                end))
        end
    end)
    return d
end

return UI
