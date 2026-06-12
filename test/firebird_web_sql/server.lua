#!/usr/bin/env lua

local Pegasus = require("pegasus")
local cjson   = require("cjson")
local config  = require("config")

local VERSION = "1.0.0"
local END_FMT = "[RTERM_END exit=%d timeout=%s duration=%d]\n"

local function now_ms()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return socket.gettime() * 1000
    end
    return os.time() * 1000
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

local function sh_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function set_cors(resp)
    resp:addHeader("Access-Control-Allow-Origin", config.cors_origin or "*")
    resp:addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    resp:addHeader("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token")
end

local function json_resp(resp, status, payload)
    resp:statusCode(status)
    resp:addHeader("Content-Type", "application/json; charset=utf-8")
    set_cors(resp)
    resp:write(cjson.encode(payload))
end

local function parse_json_body(req)
    local hdrs = req:headers()
    local len  = tonumber(hdrs["content-length"]) or 0

    if len <= 0 then
        return nil, "empty body"
    end

    local raw = req:receiveBody(len)
    if not raw or raw == "" then
        return nil, "failed to read body"
    end

    local ok, obj = pcall(cjson.decode, raw)
    if not ok then
        return nil, "json parse error: " .. tostring(obj)
    end
    if type(obj) ~= "table" then
        return nil, "body must be a json object"
    end
    if obj[1] ~= nil then
        return nil, "body must be a json object, not an array"
    end

    return obj, nil
end

local function authenticate(req)
    local hdrs  = req:headers()
    local token = hdrs["x-auth-token"]

    if not token or token == "" then
        return false, "missing X-Auth-Token header"
    end
    if token ~= config.password then
        return false, "invalid password"
    end

    return true
end

local function on_options(req, resp)
    resp:statusCode(204)
    set_cors(resp)
    resp:write("")
    log("INFO", "OPTIONS %-20s -> 204", req:path())
end

local function on_ping(req, resp)
    local ok, err = authenticate(req)
    if not ok then
        json_resp(resp, 401, { error = "unauthorized", message = err })
        log("WARN", "GET  /ping -> 401 (%s)", err)
        return
    end

    json_resp(resp, 200, {
        status    = "ok",
        version   = VERSION,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    log("INFO", "GET  /ping -> 200")
end

local function on_exec(req, resp)
    local t0 = now_ms()

    local ok, auth_err = authenticate(req)
    if not ok then
        json_resp(resp, 401, { error = "unauthorized", message = auth_err })
        log("WARN", "POST /exec -> 401 (%s)", auth_err)
        return
    end

    local body, parse_err = parse_json_body(req)
    if not body then
        json_resp(resp, 400, { error = "bad_request", message = parse_err })
        log("WARN", "POST /exec -> 400 (%s)", parse_err)
        return
    end

    local cmd = body.cmd
    if type(cmd) ~= "string" or cmd:match("^%s*$") then
        json_resp(resp, 400, {
            error   = "bad_request",
            message = "cmd field is missing or empty",
        })
        log("WARN", "POST /exec -> 400 (empty cmd)")
        return
    end

    local timeout_sec = math.max(
        config.min_timeout,
        math.min(
            tonumber(body.timeout) or config.default_timeout,
            config.max_timeout
        )
    )

    local cwd = body.cwd or config.work_dir

    log("INFO", "POST /exec cmd=%-40s timeout=%ds cwd=%s",
        string.format("%q", cmd), timeout_sec, tostring(cwd))

    local parts = {}
    if cwd and cwd ~= "" then
        parts[#parts + 1] = "cd " .. sh_quote(cwd) .. " 2>&1 &&"
    end
    parts[#parts + 1] = "timeout"
    parts[#parts + 1] = tostring(timeout_sec)
    parts[#parts + 1] = config.shell
    parts[#parts + 1] = "-c"
    parts[#parts + 1] = sh_quote(cmd)
    parts[#parts + 1] = "2>&1"

    local shell_cmd = table.concat(parts, " ")

    resp:statusCode(200)
    resp:addHeader("Content-Type", "text/plain; charset=utf-8")
    resp:addHeader("Cache-Control", "no-cache, no-store")
    resp:addHeader("X-Accel-Buffering", "no")
    resp:addHeader("Connection", "close")
    set_cors(resp)

    local proc = io.popen(shell_cmd, "r")
    if not proc then
        resp:statusCode(500)
        resp:addHeader("Content-Type", "application/json; charset=utf-8")
        resp:write(cjson.encode({
            error   = "internal",
            message = "failed to spawn subprocess",
        }))
        log("ERROR", "POST /exec -> 500 (io.popen failed, cmd=%s)", shell_cmd)
        return
    end

    local line_count = 0
    for line in proc:lines() do
        resp:write(line .. "\n", true)
        line_count = line_count + 1
    end

    local _, _, exit_code = proc:close()
    exit_code             = tonumber(exit_code) or 0
    local timed_out       = (exit_code == 124)
    local duration_ms     = math.floor(now_ms() - t0)

    resp:write(string.format(END_FMT, exit_code, tostring(timed_out), duration_ms), true)
    resp:close()

    log("INFO",
        "POST /exec done  exit=%-3d lines=%-5d dur=%-6dms timeout=%s",
        exit_code, line_count, duration_ms, tostring(timed_out))
end

local function on_not_found(req, resp)
    local m = req:method()
    local p = req:path()
    json_resp(resp, 404, {
        error   = "not_found",
        message = string.format("route not found: %s %s", m, p),
    })
    log("WARN", "%s %-20s -> 404", m, p)
end

if config.password == "changeme_PLEASE" then
    log("WARN", "!!! default password in use -- update config.lua immediately !!!")
end

log("INFO", "====================================================")
log("INFO", "  rterm %s", VERSION)
log("INFO", "  listen   : %s:%s", config.host, config.port)
log("INFO", "  shell    : %s", config.shell)
log("INFO", "  timeout  : %d ~ %d s (default %d s)",
    config.min_timeout, config.max_timeout, config.default_timeout)
log("INFO", "  work_dir : %s", tostring(config.work_dir or "(inherit)"))
log("INFO", "----------------------------------------------------")
log("INFO", "  auth     : X-Auth-Token: <password>")
log("INFO", "  ping     : curl -H 'X-Auth-Token: <pwd>' http://%s:%s/ping",
    config.host, config.port)
log("INFO", "  exec     : curl -N -X POST http://%s:%s/exec",
    config.host, config.port)
log("INFO", "             -H 'Content-Type: application/json'")
log("INFO", "             -H 'X-Auth-Token: <pwd>'")
log("INFO", "             -d '{\"cmd\":\"uname -a\"}'")
log("INFO", "----------------------------------------------------")
log("INFO", "  press Ctrl+C to stop")
log("INFO", "====================================================")

local server = Pegasus:new({
    host = config.host,
    port = config.port,
})

server:start(function(req, resp)
    local method = req:method()
    local path   = req:path()

    if method == "OPTIONS" then
        on_options(req, resp)
    elseif path == "/ping" and method == "GET" then
        on_ping(req, resp)
    elseif path == "/exec" and method == "POST" then
        on_exec(req, resp)
    else
        on_not_found(req, resp)
    end

    return true
end)
