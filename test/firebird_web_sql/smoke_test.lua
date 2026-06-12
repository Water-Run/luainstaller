--[[
Smoke test for the Firebird Web SQL Shell sample.

The test avoids a real Firebird server and validates the packaged-tool core:
mock SQL driver, CSV export, history, security capability reporting, and the
embedded Web page.
]]

local ROOT = "test/firebird_web_sql"
package.path = ROOT .. "/?.lua;" .. package.path

local db = require("db")
local history = require("history")
local security = require("security")
local web = require("web")

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
assert(caps.key_auth.enabled == true, "expected key auth flag")
assert(caps.browser_webcrypto == true, "expected WebCrypto support")

local html = web.index_html()
assert_contains(html, "Firebird Web SQL Shell")
assert_contains(html, "Access password")
assert_contains(html, "Client private key")

print("firebird_web_sql smoke test passed")
