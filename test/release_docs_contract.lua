--[[
@file test/release_docs_contract.lua
@brief Portable release-documentation contract checks for luainstaller.

Author:
    WaterRun
File:
    release_docs_contract.lua
Date:
    2026-07-17
Updated:
    2026-07-17
]]

local function read_file(path)
    local handle, open_error = io.open(path, "rb")
    assert(handle, open_error)
    local contents = handle:read("*a")
    handle:close()
    return contents
end

local function normalize_whitespace(value)
    return (value:gsub("%s+", " "))
end

local failures = {}

local function expect_contains(path, needle)
    local contents = normalize_whitespace(read_file(path))
    if not contents:find(needle, 1, true) then
        failures[#failures + 1] = string.format("%s must contain %q", path, needle)
    end
end

local function expect_contains_raw(path, needle)
    local contents = read_file(path)
    if not contents:find(needle, 1, true) then
        failures[#failures + 1] = string.format("%s must contain raw text %q", path, needle)
    end
end

local function expect_not_contains(path, needle)
    local contents = normalize_whitespace(read_file(path))
    if contents:find(needle, 1, true) then
        failures[#failures + 1] = string.format("%s must not contain %q", path, needle)
    end
end

expect_contains(
    "luainstaller-1.0.0-1.rockspec",
    'issues_url = "https://github.com/Water-Run/luainstaller/issues",'
)
expect_not_contains(
    "README.adoc",
    "The installed manual page is available as `luai(1)` and `luainstaller(1)`."
)
expect_contains_raw("docs/BUNDLING.adoc", "exact file set")

local structured_contract = "The structured result contract applies to `analyze`, `trace`, "
    .. "`compatibility`, and `bundle` only."
local logging_contract = "`getLogs` returns a list of log records; `clearLogs` returns a boolean."

for _, path in ipairs({
    "README.adoc",
    "docs/IMPLEMENTATION.adoc",
    "docs/USAGE.adoc",
}) do
    expect_contains(path, structured_contract)
    expect_contains(path, logging_contract)
end

expect_contains(
    "luainstaller.1",
    "The structured result contract applies to analyze, trace, compatibility, and bundle only."
)
expect_contains(
    "luainstaller.1",
    "getLogs returns a list of log records; clearLogs returns a boolean."
)
expect_not_contains("luainstaller.1", "Operations return a table with")

if #failures > 0 then
    error("release documentation contract failed:\n- " .. table.concat(failures, "\n- "), 0)
end

print("release documentation contract ok")
