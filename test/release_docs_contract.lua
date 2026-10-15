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
    2026-10-15
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
    "luainstaller-1.7.1-1.rockspec",
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
expect_contains("docs/USAGE.adoc", "Use manual discovery with `--include`, or use runtime discovery.")
expect_contains("docs/zh-CN/USAGE.adoc", "用手动模式配合 `--include` 列出模块， 或者改用运行时模式。")
expect_contains("docs/USAGE.adoc", "limit the combined Lua and native dependency files")
expect_contains("docs/zh-CN/USAGE.adoc", "限制 Lua 和原生依赖文件的合计数量")
for _, suite in ipairs({"dependency_limits", "source_normalization", "logger_order"}) do
    expect_contains("docs/TESTING.adoc", "test/" .. suite .. ".lua")
    expect_contains("docs/zh-CN/TESTING.adoc", "test/" .. suite .. ".lua")
    expect_contains(".github/workflows/ci.yml", "test/" .. suite .. ".lua")
    expect_contains("tools/test-lua-versions.sh", "test/" .. suite .. ".lua")
    expect_contains("tools/test-lua-versions.ps1", "'" .. suite .. ".lua'")
    expect_contains("tools/luajit-suites.txt", suite)
end

local workflow = read_file(".github/workflows/ci.yml")
local posix_matrix = assert(workflow:match("\n  version%-matrix:(.-)\n  linux%-x86%-native:"),
    "POSIX version matrix job is missing")
local windows_matrix = assert(workflow:match("\n  windows%-version%-matrix:(.*)"),
    "Windows version matrix job is missing")
for _, matrix in ipairs({
    {text=posix_matrix, artifact="posix-lua-${{ matrix.lua }}-evidence"},
    {text=windows_matrix, artifact="windows-lua-${{ matrix.lua }}-evidence"},
}) do
    for _, needle in ipairs({matrix.artifact, "if: always()", "actions/upload-artifact@",
        "*.log", "if-no-files-found: error", "retention-days: 14"}) do
        assert(matrix.text:find(needle, 1, true), "matrix evidence contract missing: " .. needle)
    end
end
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
expect_contains("docs/zh-CN/TESTING.adoc", "luainstaller-1.7.1-1.rockspec")
expect_contains("docs/TESTING.adoc", "test/no_lua_target.lua")
for _, prefix in ipairs({"docs/", "docs/zh-CN/"}) do
    expect_contains(prefix .. "LUAJIT.adoc", "--ffi-library")
    expect_contains(prefix .. "LUAJIT.adoc", "ffi_libraries")
    expect_contains(prefix .. "LUAJIT.adoc", "jit.bc")
    expect_contains(prefix .. "TROUBLESHOOTING.adoc", "[#troubleshooting-luajit]")
    for _, needle in ipairs({".github/workflows/luajit.yml", "test/luajit_mismatch.lua",
        "luajit-linux-<configuration>-evidence", "luajit-windows-<configuration>-evidence"}) do
        expect_contains(prefix .. "TESTING.adoc", needle)
    end
end
expect_contains("README.adoc", "docs/LUAJIT.adoc")
expect_contains("README.zh-CN.adoc", "docs/zh-CN/LUAJIT.adoc")
expect_not_contains("README.adoc", "LuaJIT isn't supported")
expect_not_contains("luainstaller.1", "LuaJIT is rejected")
local jit_workflow = read_file(".github/workflows/luajit.yml")
for _, needle in ipairs({"default, lua52compat, nogc64", "default, lua52compat",
    "tools/test-luajit.sh", "test-luajit.ps1", "if: always()",
    "if-no-files-found: error", "retention-days: 14"}) do
    assert(jit_workflow:find(needle, 1, true), "LuaJIT gate contract missing: " .. needle)
end
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
expect_contains("docs/TROUBLESHOOTING.adoc", "retry with the same output path")
expect_contains("docs/TROUBLESHOOTING.adoc", "doesn't guarantee durability after power loss")
expect_not_contains("docs/TROUBLESHOOTING.adoc", "Remove it once you're sure no build is running")
expect_contains("docs/zh-CN/TROUBLESHOOTING.adoc", "使用相同的输出路径重试")
expect_contains("docs/zh-CN/TROUBLESHOOTING.adoc", "不保证 断电后的持久性")

for _, prefix in ipairs({"docs/", "docs/zh-CN/"}) do
    for _, artifact in ipairs({"posix-lua-<version>-evidence", "windows-lua-<version>-evidence"}) do
        expect_contains(prefix .. "TESTING.adoc", artifact)
    end
    for _, needle in ipairs({"--file-mode", "auto", "extract", "no-extract", "moon_detect = false"}) do
        expect_contains(prefix .. "USAGE.adoc", needle)
    end
    for _, needle in ipairs({"[#troubleshooting-file-mode]", "[#troubleshooting-moonscript]",
        "moonc", "--no-moon-detect"}) do
        expect_contains(prefix .. "TROUBLESHOOTING.adoc", needle)
    end
    for _, needle in ipairs({"test/moonscript.lua", "test/moon_boundaries.lua", "test/moon_case_aliases.lua",
        "test/moon_compiler_bounds.lua",
        "test/moon_failure_cleanup.lua", "test/moon_interruption.lua",
        "test/moon_reproducibility.lua", "test/onefile_modes.lua"}) do
        expect_contains(prefix .. "TESTING.adoc", needle)
    end
    expect_contains(prefix .. "PLATFORMS-NATIVE-LIMITS.adoc", "--file-mode")
end
expect_not_contains("docs/PLATFORMS-NATIVE-LIMITS.adoc", "The single file is just an executable that unpacks itself.")
expect_not_contains("docs/zh-CN/PLATFORMS-NATIVE-LIMITS.adoc", "单文件只是一个会自行解包的可执行文件。")

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
