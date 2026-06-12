#!/usr/bin/env lua
--[[
Firebird Web SQL Shell sample server.

Author:
    WaterRun
File:
    server.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local SOURCE_DIR = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = SOURCE_DIR .. "/?.lua;" .. package.path

local Pegasus = require("pegasus")
local cjson = require("cjson")
local config = require("config")
local db = require("db")
local history = require("history")
local security = require("security")
local web = require("web")

local VERSION = "2.0.0"
local state = {
    connection = db.new({
        driver = config.default_driver,
        max_rows = config.max_rows,
        firebird = config.firebird,
    }),
    history = history.new(config.history_limit),
}

local function now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function log(level, fmt, ...)
    io.write(string.format(
        "[%s] [%-5s] %s\n",
        os.date("%Y-%m-%d %H:%M:%S"),
        level,
        string.format(fmt, ...)
    ))
    io.flush()
end

local function set_common_headers(resp, content_type)
    resp:addHeader("Content-Type", content_type or "application/json; charset=utf-8")
    resp:addHeader("Access-Control-Allow-Origin", config.cors_origin or "*")
    resp:addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    resp:addHeader("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token")
end

local function json_resp(resp, status, payload)
    resp:statusCode(status)
    set_common_headers(resp)
    resp:write(cjson.encode(payload))
end

local function text_resp(resp, status, content_type, body)
    resp:statusCode(status)
    set_common_headers(resp, content_type)
    resp:write(body or "")
end

local function parse_json_body(req)
    local headers = req:headers()
    local len = tonumber(headers["content-length"]) or 0
    if len <= 0 then
        return {}
    end
    local raw = req:receiveBody(len)
    if not raw or raw == "" then
        return nil, "failed to read body"
    end
    local ok, obj = pcall(cjson.decode, raw)
    if not ok or type(obj) ~= "table" then
        return nil, "body must be a JSON object"
    end
    return obj
end

local function authenticated(req)
    if config.token == "" then
        return true
    end
    local headers = req:headers()
    return headers["x-auth-token"] == config.token
end

local function require_auth(req, resp)
    if authenticated(req) then
        return true
    end
    json_resp(resp, 401, {
        ok = false,
        error = "unauthorized",
        message = "missing or invalid X-Auth-Token",
    })
    return false
end

local function route_status(req, resp)
    if not require_auth(req, resp) then
        return
    end
    json_resp(resp, 200, {
        ok = true,
        version = VERSION,
        timestamp = now(),
        connection = state.connection:status(),
        max_rows = config.max_rows,
        security = security.capabilities(config.key_auth),
    })
end

local function route_connect(req, resp)
    if not require_auth(req, resp) then
        return
    end
    local body, err = parse_json_body(req)
    if not body then
        json_resp(resp, 400, { ok = false, error = "bad_request", message = err })
        return
    end
    local next_conn = db.new({
        driver = body.driver or config.default_driver,
        max_rows = tonumber(body.max_rows) or config.max_rows,
        firebird = {
            host = body.host or config.firebird.host,
            database = body.database or config.firebird.database,
            user = body.user or config.firebird.user,
            password = body.password or config.firebird.password,
            role = body.role or config.firebird.role,
            charset = body.charset or config.firebird.charset,
        },
    })
    local ok, connect_err = next_conn:connect()
    if not ok then
        json_resp(resp, 400, { ok = false, error = "connect_failed", message = connect_err })
        return
    end
    state.connection:close()
    state.connection = next_conn
    json_resp(resp, 200, { ok = true, connection = state.connection:status() })
end

local function route_query(req, resp)
    if not require_auth(req, resp) then
        return
    end
    local body, err = parse_json_body(req)
    if not body then
        json_resp(resp, 400, { ok = false, error = "bad_request", message = err })
        return
    end
    local sql = tostring(body.sql or "")
    local result, query_err = state.connection:query(sql, {
        max_rows = tonumber(body.max_rows) or config.max_rows,
    })
    if not result then
        state.history:add(sql, false, query_err)
        json_resp(resp, 400, { ok = false, error = "query_failed", message = query_err })
        return
    end
    state.history:add(sql, true, result.summary)
    json_resp(resp, 200, { ok = true, result = result })
end

local function route_execute(req, resp)
    route_query(req, resp)
end

local function route_tables(req, resp)
    if not require_auth(req, resp) then
        return
    end
    local tables, err = state.connection:tables()
    if not tables then
        json_resp(resp, 400, { ok = false, error = "schema_failed", message = err })
        return
    end
    json_resp(resp, 200, { ok = true, tables = tables })
end

local function route_table(req, resp, name)
    if not require_auth(req, resp) then
        return
    end
    local info, err = state.connection:table_info(name)
    if not info then
        json_resp(resp, 404, { ok = false, error = "table_not_found", message = err })
        return
    end
    json_resp(resp, 200, { ok = true, table = info })
end

local function route_history(req, resp)
    if not require_auth(req, resp) then
        return
    end
    json_resp(resp, 200, { ok = true, history = state.history:list() })
end

local function route_history_clear(req, resp)
    if not require_auth(req, resp) then
        return
    end
    state.history:clear()
    json_resp(resp, 200, { ok = true })
end

local function route_export_csv(req, resp)
    if not require_auth(req, resp) then
        return
    end
    local body, err = parse_json_body(req)
    if not body then
        json_resp(resp, 400, { ok = false, error = "bad_request", message = err })
        return
    end
    local result, query_err = state.connection:query(tostring(body.sql or ""), {
        max_rows = tonumber(body.max_rows) or config.max_rows,
    })
    if not result then
        json_resp(resp, 400, { ok = false, error = "query_failed", message = query_err })
        return
    end
    text_resp(resp, 200, "text/csv; charset=utf-8", db.to_csv(result.columns, result.rows))
end

local function route_not_found(req, resp)
    json_resp(resp, 404, {
        ok = false,
        error = "not_found",
        message = req:method() .. " " .. req:path(),
    })
end

local function dispatch(req, resp)
    local method = req:method()
    local path = req:path()

    if method == "OPTIONS" then
        resp:statusCode(204)
        set_common_headers(resp)
        resp:write("")
    elseif method == "GET" and path == "/" then
        text_resp(resp, 200, "text/html; charset=utf-8", web.index_html())
    elseif method == "GET" and path == "/api/status" then
        route_status(req, resp)
    elseif method == "POST" and path == "/api/connect" then
        route_connect(req, resp)
    elseif method == "POST" and path == "/api/query" then
        route_query(req, resp)
    elseif method == "POST" and path == "/api/execute" then
        route_execute(req, resp)
    elseif method == "GET" and path == "/api/tables" then
        route_tables(req, resp)
    elseif method == "GET" and path:match("^/api/table/") then
        route_table(req, resp, path:match("^/api/table/(.+)$"))
    elseif method == "GET" and path == "/api/history" then
        route_history(req, resp)
    elseif method == "POST" and path == "/api/history/clear" then
        route_history_clear(req, resp)
    elseif method == "POST" and path == "/api/export/csv" then
        route_export_csv(req, resp)
    else
        route_not_found(req, resp)
    end

    return true
end

if config.token == "changeme_PLEASE" then
    log("WARN", "default token in use; set FIREBIRD_WEB_SQL_TOKEN for real use")
end

log("INFO", "Firebird Web SQL Shell %s", VERSION)
log("INFO", "listen: http://%s:%s", config.host, config.port)
log("INFO", "driver: %s", config.default_driver)
log("INFO", "auth: X-Auth-Token")

local server = Pegasus:new({
    host = config.host,
    port = config.port,
})

server:start(dispatch)
