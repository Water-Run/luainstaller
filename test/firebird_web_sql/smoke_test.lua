--[[
Smoke test for the Firebird Web SQL Shell sample.

The test avoids a real Firebird server and validates the packaged-tool core:
mock SQL driver, CSV export, history, security capability reporting, and the
embedded Web page.

Author:
    WaterRun
File:
    smoke_test.lua
Date:
    2026-06-14
Updated:
    2026-10-12
]]
local ROOT = "test/firebird_web_sql"
package.path = ROOT .. "/?.lua;" .. package.path

local db = require("db")
local history = require("history")
local security = require("security")
local web = require("web")

assert(type(security.validateConfiguration) == "function", "sample has no startup security policy")
local safe = {host="127.0.0.1", token=string.rep("test", 8), max_body_bytes=65536}
assert(security.validateConfiguration(safe))
for _, token in ipairs({"", "changeme_PLEASE", "short"}) do
    assert(not security.validateConfiguration({host="127.0.0.1", token=token}),
        "weak sample token was accepted")
end
assert(not security.validateConfiguration({host="0.0.0.0", token=safe.token}),
    "sample accepted a public listener")
local received = false
local body, body_error = security.readJsonBody({
    headers=function() return {["content-length"]="999999999"} end,
    receiveBody=function() received=true; return "{}" end,
}, function() return {} end, 65536)
assert(body == nil and body_error and not received, "oversized body was read")

local function assert_contains(text, pattern)
    if not tostring(text):find(pattern, 1, true) then
        error("expected text to contain " .. pattern, 2)
    end
end

local conn = db.new({ driver = "mock", max_rows = 10 })
assert(conn:connect())

local result = assert(conn:query("select * from employee"))
assert(result.row_count == 4, "expected mock employee rows")
assert(result.columns[1] == "ID", "expected ID column")

local count = assert(conn:query("select count(*) from employee"))
assert(count.rows[1].COUNT == 4, "expected employee count")
assert(not conn:query("select * from employee", {max_rows=math.huge}))
assert(not conn:query(string.rep("x", 16385)))
assert(not db.new({driver="luasql-firebird", firebird={password="masterkey"}}):connect())

local tables = assert(conn:tables())
assert(#tables >= 2, "expected mock tables")

local info = assert(conn:table_info("employee"))
assert(info.name == "EMPLOYEE", "expected table info")

local csv = db.to_csv(result.columns, result.rows)
assert_contains(csv, "Ada Lovelace")

local hist = history.new(3)
hist:add("select * from employee", true, "4 rows")
hist:add("bad sql", false, "failed")
assert(#hist:list() == 2, "expected history entries")
hist:clear()
assert(#hist:list() == 0, "expected cleared history")

local caps = security.capabilities({ enabled = true, trusted_public_keys = "client.pem" })
assert(caps.password_header == true, "expected password header support")
assert(caps.key_auth.enabled == false and caps.key_auth.requested == true,
    "unimplemented client-key authentication was reported as enabled")
assert(caps.app_encryption == false, "unimplemented application encryption was advertised")
assert(caps.browser_webcrypto == true, "expected WebCrypto support")

local html = web.index_html()
assert_contains(html, "Firebird Web SQL Shell")
assert_contains(html, "Access password")
assert_contains(html, "Client private key")

print("firebird_web_sql smoke test passed")
