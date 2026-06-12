--[[
Security capability helper for the Firebird Web SQL Shell sample.

Author:
    WaterRun
File:
    security.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local M = {}

local function load_luaossl()
    local loader = _G.require
    local ok, openssl = pcall(loader, "openssl")
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
            enabled = key_auth.enabled == true,
            configured = tostring(key_auth.trusted_public_keys or "") ~= "",
            header_scheme = "X-Client-Id + X-Timestamp + X-Signature",
        },
        browser_webcrypto = true,
        app_encryption = openssl ~= nil,
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
