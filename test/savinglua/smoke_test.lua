--[[
Smoke test for the savinglua SQLite-backed table store sample.

The test uses a temporary database and validates the packaged-tool core:
schema initialization, JSON table persistence, lookup, prefix scanning,
deletion, and the command-line interface.

Author:
    WaterRun
File:
    smoke_test.lua
Date:
    2026-06-14
Updated:
    2026-07-18
]]
local ROOT = "test/savinglua"
package.path = ROOT .. "/src/?.lua;" .. package.path
local harness = dofile("test/support/harness.lua")

local store = require("savinglua.store")

local DB = os.tmpname() .. ".sqlite3"

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected text to contain " .. pattern .. "\nactual:\n" .. tostring(text), 2)
    end
end

local function run(arguments)
    local command_arguments = {
        ROOT .. "/main.lua",
        "--db",
        DB,
    }
    for _, argument in ipairs(arguments) do
        command_arguments[#command_arguments + 1] = argument
    end
    return harness.run(harness.command(harness.lua_command(), command_arguments))
end

os.remove(DB)

local db = assert(store.open(DB))
assert(db:put("users:ada", {
    name = "Ada Lovelace",
    tags = { "math", "programming" },
    score = 98,
}))
assert(db:put("users:grace", {
    name = "Grace Hopper",
    tags = { "compiler" },
    score = 95,
}))

local ada = assert(db:get("users:ada"))
assert(ada.name == "Ada Lovelace", "expected persisted table record")
assert(ada.tags[2] == "programming", "expected array fields to round-trip")

local rows = assert(db:scan("users:"))
assert(#rows == 2, "expected two prefixed records")
assert(rows[1].key == "users:ada", "expected deterministic key ordering")

assert(db:delete("users:grace"))
assert(db:get("users:grace") == nil, "expected deleted record to be absent")
db:close()

assert_contains(run({ "put", "sessions:demo", '{"ok":true,"count":3}' }),
    "stored sessions:demo")
assert_contains(run({ "get", "sessions:demo" }), "\"count\":3")
assert_contains(run({ "scan", "users:" }), "users:ada")
assert_contains(run({ "delete", "sessions:demo" }), "deleted sessions:demo")

os.remove(DB)

print("savinglua smoke test passed")
