--[[
Security capability helper for the Firebird Web SQL Shell sample.

Author:
    WaterRun
File:
    security.lua
Date:
    2026-06-12
Updated:
    2026-10-12
]]

local M = {}

function M.validateConfiguration(config)
    if config.host ~= "127.0.0.1" and config.host ~= "::1" then
        return nil, "The sample listens on loopback only; use a trusted HTTPS proxy for remote access."
    end
    if type(config.token) ~= "string" or #config.token < 32 or #config.token > 512
        or config.token:find("\0", 1, true) then
        return nil, "Set FIREBIRD_WEB_SQL_TOKEN to a private token of at least 32 bytes."
    end
    if config.cors_origin == "*" then
        return nil, "Set a specific FIREBIRD_WEB_SQL_CORS origin or leave it empty."
    end
    if config.key_auth and config.key_auth.enabled then
        return nil, "The sample does not implement client-key authentication; use X-Auth-Token."
    end
    return true
end

function M.readJsonBody(req, decode, limit)
    local headers = req:headers()
    if headers["transfer-encoding"] then return nil, "transfer encoding is not supported" end
    local raw_length = headers["content-length"]
    if raw_length == nil then return {} end
    if type(raw_length) ~= "string" or not raw_length:match("^%d+$") then
        return nil, "invalid content length"
    end
    local length = tonumber(raw_length)
    if not length or length > limit then return nil, "request body exceeds the byte limit" end
    if length == 0 then return {} end
    local received, raw = pcall(req.receiveBody, req, length)
    if not received or type(raw) ~= "string" or #raw ~= length then
        return nil, "failed to read complete body"
    end
    if not raw:match("^%s*{") then return nil, "body must be a JSON object" end
    local ok, object = pcall(decode, raw)
    if not ok or type(object) ~= "table" then return nil, "body must be a JSON object" end
    return object
end

local function load_luaossl()
    local ok, openssl = pcall(require, "openssl")
    if ok then
        return openssl
    end
    return nil
end

function M.capabilities(key_auth)
    local openssl = load_luaossl()
    key_auth = key_auth or {}
    return {
        password_header = true,
        key_auth = {
            enabled = false,
            requested = key_auth.enabled == true,
            configured = tostring(key_auth.trusted_public_keys or "") ~= "",
            header_scheme = "X-Client-Id + X-Timestamp + X-Signature",
        },
        browser_webcrypto = true,
        app_encryption = false,
        server_crypto = openssl and "luaossl" or nil,
        recommended = {
            "luaossl for OpenSSL-backed RSA/AES/HMAC on the Lua server",
            "WebCrypto in the browser for RSA-OAEP and AES-GCM",
            "plc as a pure Lua research fallback for NaCl-style primitives",
        },
        warning = "Application-layer encryption over HTTP protects against passive capture only when the delivered page is trusted. Use HTTPS against active MITM.",
    }
end

return M
