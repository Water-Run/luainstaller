#!/usr/bin/env lua
--[[
Sample Lua program for luainstaller test coverage.

Author:
    WaterRun
File:
    main.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]

local ROOT = debug.getinfo(1, "S").source:sub(2):match("^(.*)/main%.lua$") or "."
package.path = ROOT .. "/src/?.lua;" .. package.path

local cjson = require("cjson")
local store = require("savinglua.store")

local function usage()
    io.stderr:write(table.concat({
        "Usage:",
        "  lua test/savinglua/main.lua --db <file> put <key> <json-object>",
        "  lua test/savinglua/main.lua --db <file> get <key>",
        "  lua test/savinglua/main.lua --db <file> scan [prefix]",
        "  lua test/savinglua/main.lua --db <file> delete <key>",
        "",
    }, "\n"))
end

local function parse(args)
    local opts = { db = "savinglua.sqlite3", positionals = {} }
    local i = 1
    while i <= #args do
        local item = args[i]
        if item == "--db" then
            opts.db = args[i + 1]
            i = i + 2
        else
            opts.positionals[#opts.positionals + 1] = item
            i = i + 1
        end
    end
    return opts
end

local function die(message)
    io.stderr:write(tostring(message), "\n")
    os.exit(1)
end

local opts = parse(arg or {})
local command = opts.positionals[1]
if not command then
    usage()
    os.exit(1)
end

local db, err = store.open(opts.db)
if not db then
    die(err)
end

if command == "put" then
    local key = opts.positionals[2] or die("key is required")
    local raw = opts.positionals[3] or die("json object is required")
    local ok, value = pcall(cjson.decode, raw)
    if not ok or type(value) ~= "table" then
        die("json object is invalid")
    end
    local saved, save_err = db:put(key, value)
    if not saved then
        die(save_err)
    end
    print("stored " .. key)
elseif command == "get" then
    local key = opts.positionals[2] or die("key is required")
    local value, get_err = db:get(key)
    if get_err then
        die(get_err)
    end
    if value then
        print(cjson.encode(value))
    else
        print("not found " .. key)
    end
elseif command == "scan" then
    local prefix = opts.positionals[2] or ""
    local rows, scan_err = db:scan(prefix)
    if not rows then
        die(scan_err)
    end
    for _, row in ipairs(rows) do
        print(row.key .. "\t" .. cjson.encode(row.value))
    end
elseif command == "delete" then
    local key = opts.positionals[2] or die("key is required")
    local ok, delete_err = db:delete(key)
    if not ok then
        die(delete_err)
    end
    print("deleted " .. key)
else
    usage()
    os.exit(1)
end

db:close()
