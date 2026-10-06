--[[
@file test/release_docs_contract.lua
@brief Portable release-documentation contract checks for luainstaller.

Author:
    WaterRun
File:
    release_docs_contract.lua
Date:
    2026-08-22
Updated:
    2026-10-06
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
    "luainstaller-1.5.0-1.rockspec",
    'issues_url = "https://github.com/Water-Run/luainstaller/issues",'
)
expect_not_contains(
    "README.adoc",
    "The installed manual page is available as `luai(1)` and `luainstaller(1)`."
)
expect_contains_raw("docs/BUNDLING.adoc", "exact file set")
for _, doc in ipairs({ "README.adoc", "docs/INSTALL.adoc", "docs/PLATFORMS-NATIVE-LIMITS.adoc" }) do
    expect_contains(doc, "Lua headers aren't needed")
end
expect_contains("docs/RELINKING.adoc", "`lua_min.h`")
expect_not_contains("docs/RELINKING.adoc", "interpreter, headers, and library")
expect_contains("luainstaller.1", "Lua headers are not required")
expect_contains("docs/PLATFORMS-NATIVE-LIMITS.adoc", "These warnings don't stop the build")
expect_contains("docs/PLATFORMS-NATIVE-LIMITS.adoc", "weren't checked")
expect_contains("docs/USAGE.adoc", "Build results include a `warnings` list")
expect_contains("CHANGELOG.adoc", "This release reduces build setup")
expect_contains("CHANGELOG.adoc", "Lua headers and development metadata aren't required")
expect_contains("README.adoc", "A Lua library that matches that interpreter's version")
expect_contains("README.zh-CN.adoc", "构建可执行文件不需要 Lua 头文件")
expect_not_contains("README.zh-CN.adoc", "Lua 头文件和 Lua 库")
expect_contains("docs/zh-CN/INSTALL.adoc", "不需要 Lua 头文件")
expect_contains("docs/zh-CN/PLATFORMS-NATIVE-LIMITS.adoc", "DLL 依赖未检查")
expect_contains("docs/zh-CN/PLATFORMS-NATIVE-LIMITS.adoc", "这些告警不会阻止构建")
expect_contains("docs/zh-CN/RELINKING.adoc", "`lua_min.h`")
expect_contains("docs/zh-CN/TROUBLESHOOTING.adoc", "troubleshooting-native-dependencies")
expect_contains("docs/zh-CN/TESTING.adoc", "luainstaller-1.5.0-1.rockspec")
expect_contains("docs/TESTING.adoc", "test/no_lua_target.lua")
expect_contains("docs/zh-CN/TESTING.adoc", "test/no_lua_target.lua")
expect_contains("docs/INSTALL.adoc", "PowerShell isn't needed")
expect_contains("docs/PLATFORMS-NATIVE-LIMITS.adoc",
    "Installation, packaging and the generated programs don't need PowerShell.")
expect_contains("docs/zh-CN/PLATFORMS-NATIVE-LIMITS.adoc",
    "安装、打包和生成的程序都不需要 PowerShell。")
for _, doc in ipairs({ "docs/INSTALL.adoc", "docs/PLATFORMS-NATIVE-LIMITS.adoc",
    "docs/zh-CN/INSTALL.adoc", "docs/zh-CN/PLATFORMS-NATIVE-LIMITS.adoc" }) do
    expect_not_contains(doc, "PowerShell 2")
end
expect_contains("docs/TROUBLESHOOTING.adoc",
    "Copying a C module with the same filename doesn't make the dependency discoverable.")
expect_contains("docs/zh-CN/TROUBLESHOOTING.adoc",
    "复制一个同名的 C 模块，也不代表加载器就能找到该依赖。")

local structured_contract = "The structured result contract applies to `analyze`, `trace`, "
    .. "`compatibility`, and `bundle` only."
local logging_contract = "`getLogs` returns a list of log records; `clearLogs` returns a boolean."

expect_contains("docs/IMPLEMENTATION.adoc", structured_contract)
expect_contains("docs/IMPLEMENTATION.adoc", logging_contract)
for _, needle in ipairs({ "getLogs", "clearLogs", "compatibility" }) do
    expect_contains("docs/USAGE.adoc", needle)
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
