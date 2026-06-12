--[[
Configuration for the Firebird Web SQL Shell sample.

Author:
    WaterRun
File:
    config.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local config = {
    host = os.getenv("FIREBIRD_WEB_SQL_HOST") or "127.0.0.1",
    port = os.getenv("FIREBIRD_WEB_SQL_PORT") or "9090",

    token = os.getenv("FIREBIRD_WEB_SQL_TOKEN") or "changeme_PLEASE",
    cors_origin = os.getenv("FIREBIRD_WEB_SQL_CORS") or "*",

    default_driver = os.getenv("FIREBIRD_WEB_SQL_DRIVER") or "mock",
    max_rows = tonumber(os.getenv("FIREBIRD_WEB_SQL_MAX_ROWS")) or 500,
    history_limit = tonumber(os.getenv("FIREBIRD_WEB_SQL_HISTORY_LIMIT")) or 80,

    firebird = {
        host = os.getenv("FIREBIRD_HOST") or "127.0.0.1",
        database = os.getenv("FIREBIRD_DATABASE") or "",
        user = os.getenv("FIREBIRD_USER") or "SYSDBA",
        password = os.getenv("FIREBIRD_PASSWORD") or "masterkey",
        role = os.getenv("FIREBIRD_ROLE") or "",
        charset = os.getenv("FIREBIRD_CHARSET") or "UTF8",
    },

    key_auth = {
        enabled = os.getenv("FIREBIRD_WEB_SQL_KEY_AUTH") == "1",
        trusted_public_keys = os.getenv("FIREBIRD_WEB_SQL_PUBLIC_KEYS") or "",
    },
}

return config
