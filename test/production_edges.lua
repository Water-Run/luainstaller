--[[
Production hardening regression suite for luainstaller.

Author:
    WaterRun
File:
    production_edges.lua
Date:
    2026-07-11
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fileExists = harness.file_exists
local makeDirectory = harness.mkdir
local makeTempDir = harness.make_temp_dir
local removeTree = harness.remove_tree
local readFile = harness.read_file
local writeFile = harness.write_file
local shellQuote = harness.shell_quote
local commandOutputTrimmed = harness.command_output_trimmed
local runCommand = harness.run
local commandResult = harness.command_result
local function commandSucceeds(command)
    local ok = commandResult(command)
    return ok
end
local luaCommand = shellQuote(harness.lua_command())
local compat = require("luainstaller.compat")
local loadText = compat.loadText
local packValues = compat.pack
local unpackValues = compat.unpack

local function selectedLinuxRuntime()
    local info = compat.luaVersion()
    local prefix = os.getenv("LUAI_LUA_PREFIX")
    if type(prefix) == "string" and prefix ~= "" then
        local runtime = string.format(
            "%s/lib/liblua.so.%d.%d",
            prefix,
            info.major,
            info.minor
        )
        if require("luainstaller.fs").isRegularFile(runtime) then
            return require("luainstaller.path").basename(runtime), runtime
        end
    end
    local lua_binary = harness.lua_command()
    if not require("luainstaller.path").isAbsolute(lua_binary) then
        lua_binary = commandOutputTrimmed("command -v " .. shellQuote(lua_binary))
    end
    local ldd = runCommand("LC_ALL=C ldd " .. shellQuote(lua_binary))
    local runtime_name, runtime_path = ldd:match(
        "(liblua[^%s]*)%s+=>%s+([^%s]+)"
    )
    if runtime_path == "not" then return nil end
    return runtime_name, runtime_path
end

local native_fixture_config
local function compileNativeFixture(source_path, output_path)
    if not native_fixture_config then
        local config, config_err = require("luainstaller.toolchain").resolve()
        assert(config, config_err and config_err.error
            and config_err.error.message or "native fixture toolchain unavailable")
        native_fixture_config = config
    end
    local compiled, output, command = require("luainstaller.toolchain").compileNativeModule(
        native_fixture_config,
        source_path,
        output_path,
        { work_dir = require("luainstaller.path").dirname(output_path) }
    )
    assert(compiled, table.concat({
        tostring(command or "native fixture compile failed"),
        tostring(output or ""),
    }, "\n"))
    if native_fixture_config.host.os == "linux" then
        assert(not tostring(command):find("-llua", 1, true),
            "ordinary Linux fixture linked a private liblua")
    end
    return command
end

local tests = {}

local function test(name, fn)
    tests[#tests + 1] = {
        name = name,
        fn = fn,
    }
end

local function assertEqual(actual, expected, label)
    assert(actual == expected, string.format(
        "%s: expected %q, got %q",
        tostring(label or "value"),
        tostring(expected),
        tostring(actual)
    ))
end

test("FNV-1a matches standard 32-bit vectors on every Lua number model", function()
    local fnv1a32 = require("luainstaller.hash").fnv1a32
    for _, vector in ipairs({
        { content = "", expected = "811c9dc5" },
        { content = "a", expected = "e40c292c" },
        { content = "foobar", expected = "bf9cf968" },
        { content = "hello", expected = "4f9f2cab" },
    }) do
        assertEqual(fnv1a32(vector.content), vector.expected,
            "FNV-1a vector " .. string.format("%q", vector.content))
    end
end)

test("native fixture exercises version-specific Lua C APIs", function()
    local source = readFile("test/fixtures/native_probe.c")
    for _, contract in ipairs({
        "LUA_VERSION_NUM == 501",
        "lua_objlen",
        "LUA_VERSION_NUM == 502",
        "lua_absindex",
        "LUA_VERSION_NUM == 503",
        "lua_isinteger",
        "LUA_VERSION_NUM == 504",
        "lua_newuserdatauv",
        "LUA_VERSION_NUM == 505",
        "lua_numbertocstring",
        "luaL_checkversion",
    }) do
        assert(source:find(contract, 1, true),
            "native ABI fixture omits " .. contract)
    end
end)

test("test harness preserves child output and nonzero exit status", function()
    local command
    if package.config:sub(1, 1) == "\\" then
        command = '<nul set /p "=harness-status-output"&exit /b 7'
    else
        command = "printf harness-status-output; exit 7"
    end
    local ok, output, status = harness.command_result(command)
    assert(not ok, "nonzero child status was reported as success")
    assertEqual(status, 7, "child exit status")
    assertEqual(output, "harness-status-output", "child output")
end)

test("full edge-coverage prerequisites are available", function()
    if os.getenv("LUAI_REQUIRE_FULL_EDGE_COVERAGE") ~= "1" then return end
    assert(package.config:sub(1, 1) == "/", "full edge coverage requires a POSIX host")
    assertEqual(commandOutputTrimmed("uname -s"), "Linux", "full edge coverage host")
    for _, command in ipairs({
        "cc", "clang", "luajit", "pkg-config", "sha256sum",
        "x86_64-w64-mingw32-gcc",
    }) do
        local available = commandSucceeds("command -v " .. command .. " >/dev/null 2>&1")
        assert(available,
            "full edge coverage is missing command: " .. command)
    end
    local full = io.open("/dev/full", "wb")
    assert(full, "full edge coverage requires /dev/full")
    full:close()
    local runtime_name, runtime_path = selectedLinuxRuntime()
    assert(runtime_name and runtime_path,
        "full edge coverage could not identify the selected Lua runtime")
    local dynamic = runCommand("LC_ALL=C readelf -d " .. shellQuote(runtime_path))
    assert(dynamic:find("Library soname: [" .. runtime_name .. "]", 1, true),
        "selected Lua runtime does not expose its ABI SONAME")
    local prefix = os.getenv("LUAI_LUA_PREFIX")
    if type(prefix) == "string" and prefix ~= "" then
        assertEqual(commandOutputTrimmed("pkg-config --modversion lua"),
            os.getenv("LUAI_LUA_RELEASE"), "selected pkg-config Lua release")
        assertEqual(commandOutputTrimmed("pkg-config --variable=includedir lua"),
            prefix .. "/include", "selected pkg-config Lua headers")
    end
    local root = makeTempDir("coverage-prerequisites")
    local unreadable = root .. "/unreadable"
    makeDirectory(unreadable)
    runCommand("chmod 000 " .. shellQuote(unreadable))
    local inaccessible = commandSucceeds("test ! -r " .. shellQuote(unreadable))
    runCommand("chmod 700 " .. shellQuote(unreadable))
    removeTree(root)
    assert(inaccessible,
        "full edge coverage must run as a user affected by permission bits")
    io.write("full edge prerequisites enforced\n")
end)

local function fnv1a32Collision(content)
    assert(#content >= 5, "collision fixture must be at least five bytes")
    local prime = 16777619
    local inverse = 899433627
    local bxor = require("luainstaller.compat").bxor
    local function multiply32(left, right)
        local left_low = left % 65536
        local left_high = math.floor(left / 65536)
        local right_low = right % 65536
        local right_high = math.floor(right / 65536)
        local low_product = left_low * right_low
        local low = low_product % 65536
        local high = (left_high * right_low + left_low * right_high
            + math.floor(low_product / 65536)) % 65536
        return high * 65536 + low
    end
    local function step(state, byte)
        return multiply32(bxor(state, byte), prime)
    end
    local state = 2166136261
    local prefix = content:sub(1, -6)
    for index = 1, #prefix do
        state = step(state, prefix:byte(index))
    end
    local forward = {}
    for first = 0, 255 do
        local once = step(state, first)
        for second = 0, 255 do
            local twice = step(once, second)
            if forward[twice] == nil then
                forward[twice] = string.char(first, second)
            end
        end
    end

    local target = tonumber(require("luainstaller.hash").fnv1a32(content), 16)
    local original_suffix = content:sub(-5)
    for fifth = 0, 255 do
        local before_fifth = bxor(multiply32(target, inverse), fifth)
        for fourth = 0, 255 do
            local before_fourth = bxor(multiply32(before_fifth, inverse), fourth)
            for third = 0, 255 do
                local before_third = bxor(multiply32(before_fourth, inverse), third)
                local first_two = forward[before_third]
                if first_two then
                    local suffix = first_two .. string.char(third, fourth, fifth)
                    if suffix ~= original_suffix then
                        return prefix .. suffix
                    end
                end
            end
        end
    end
    error("failed to construct an FNV-1a collision")
end

test("sha256 known vectors", function()
    local hash = require("luainstaller.hash")
    assertEqual(
        hash.sha256(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty vector"
    )
    assertEqual(
        hash.sha256("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "abc vector"
    )
    assertEqual(
        hash.sha256("The quick brown fox jumps over the lazy dog"),
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
        "quick-brown-fox vector"
    )
end)

test("sha256 matches the host across block boundaries and binary data", function()
    local available = commandSucceeds("command -v sha256sum >/dev/null 2>&1")
    if not available then
        return
    end
    local root = makeTempDir("sha256-differential")
    local hash = require("luainstaller.hash")
    local sizes = {
        0, 1, 31, 55, 56, 57, 63, 64, 65,
        127, 128, 129, 1000, 1024 * 1024,
    }
    for _, size in ipairs(sizes) do
        local bytes = {}
        for index = 1, size do
            bytes[index] = string.char((index * 131 + 17) % 256)
        end
        local content = table.concat(bytes)
        local path = root .. "/fixture-" .. size .. ".bin"
        writeFile(path, content)
        local expected = commandOutputTrimmed("sha256sum " .. shellQuote(path)):match("^[0-9a-f]+")
        assertEqual(hash.sha256(content), expected, "SHA-256 size " .. size)
    end
    removeTree(root)
end)

test("checked write reports flush or close failure", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local probe = io.open("/dev/full", "wb")
    if not probe then
        return
    end
    probe:close()

    local fs = require("luainstaller.fs")
    local ok, err = fs.writeFile("/dev/full", "not silently successful")
    assert(ok == nil)
    assert(type(err) == "string" and err ~= "")
end)

test("Windows regular-file checks use a non-follow type query", function()
    local original_process = require("luainstaller.process")
    local original_config = package.config
    local original_getenv = os.getenv
    local calls = 0
    rawset(package, "config", "\\\n;\n?\n!\n-")
    local windows_process = dofile("src/process.lua")
    windows_process.output = function(command)
        calls = calls + 1
        local powershell_position = command:find(
            "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            1,
            true
        )
        assert(powershell_position and powershell_position <= 2,
            "Windows type query depended on PATH for PowerShell")
        assert(command:find("-EncodedCommand", 1, true),
            "Windows type query did not encode its PowerShell script")
        assert(not command:find("NUL&echo unsafe", 1, true), "raw Windows path reached the shell")
        return true, calls == 1 and "other" or "file"
    end
    rawset(os, "getenv", function(name)
        if name == "SystemRoot" then return "C:\\Windows" end
        return original_getenv(name)
    end)
    package.loaded["luainstaller.process"] = windows_process
    local loaded, windows_fs = pcall(dofile, "src/fs.lua")
    if not loaded then
        rawset(package, "config", original_config)
        package.loaded["luainstaller.process"] = original_process
        rawset(os, "getenv", original_getenv)
        error(windows_fs)
    end
    local device = windows_fs.isRegularFile("NUL&echo unsafe")
    local regular = windows_fs.isRegularFile("C:\\safe\\empty.lua")
    rawset(package, "config", original_config)
    package.loaded["luainstaller.process"] = original_process
    rawset(os, "getenv", original_getenv)

    assert(not device, "Windows device was accepted as a regular file")
    assert(regular, "Windows regular-file type result was ignored")
    assertEqual(calls, 2, "Windows type query count")
end)

test("Windows PowerShell helper is absolute and rejects shell metacharacters", function()
    local process = require("luainstaller.process")
    local original_getenv = os.getenv
    rawset(os, "getenv", function(name)
        if name == "SystemRoot" then return "D:\\Windows Root" end
        return original_getenv(name)
    end)
    local ok, resolved = pcall(process.windowsPowerShellPath)
    rawset(os, "getenv", function(name)
        if name == "SystemRoot" then return "" end
        if name == "WINDIR" then return "E:\\WinNT" end
        return original_getenv(name)
    end)
    local fallback_ok, fallback = pcall(process.windowsPowerShellPath)
    rawset(os, "getenv", function(name)
        if name == "SystemRoot" then return "C:\\Windows&echo unsafe" end
        return original_getenv(name)
    end)
    local unsafe_ok, unsafe = pcall(process.windowsPowerShellPath)
    rawset(os, "getenv", original_getenv)

    assert(ok, "Windows PowerShell path helper is unavailable")
    assertEqual(
        resolved,
        "D:\\Windows Root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "absolute Windows PowerShell path"
    )
    assert(fallback_ok, "WINDIR fallback raised an error")
    assertEqual(
        fallback,
        "E:\\WinNT\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "WINDIR fallback path"
    )
    assert(unsafe_ok and unsafe == nil, "unsafe SystemRoot reached a shell command")
end)

test("Windows logger delegates encoded filesystem operations", function()
    local logger_source = readFile("src/logger.lua")
    local fs_source = readFile("src/fs.lua")
    assert(fs_source:find("FromBase64String", 1, true),
        "Windows filesystem backend does not encode paths and file contents")
    assert(fs_source:find("[Text.Encoding]::UTF8.GetString", 1, true),
        "Windows filesystem backend does not decode paths as UTF-8")
    for _, operation in ipairs({ "fs.pathType", "fs.writeFile", "fs.rename", "fs.removeFile" }) do
        assert(logger_source:find(operation, 1, true),
            "Windows logger does not delegate to checked operation " .. operation)
    end
    assert(not logger_source:find("windowsCommandPathIsSafe", 1, true),
        "Windows logger rejects legal filesystem metacharacters")
end)

test("path roots and safe relatives", function()
    local path = require("luainstaller.path")
    assertEqual(path.dirname("/main.lua"), "/", "POSIX root parent")
    assertEqual(path.dirname("C:/main.lua"), "C:/", "drive root parent")
    assertEqual(path.dirname("//server/share.lua"), "//server/share.lua", "UNC share root parent")
    assertEqual(path.normalize("//server/share/.."), "//server/share", "UNC share traversal")
    assertEqual(path.dirname("//server/share"), "//server/share", "UNC share root parent")
    assertEqual(path.dirname("//server/share/main.lua"), "//server/share", "UNC share child parent")
    assert(path.isAbsolute("\\\\server\\share\\main.lua"), "backslash UNC path must be absolute")
    assertEqual(path.join("/", "main.lua"), "/main.lua", "POSIX root join")
    assertEqual(path.join("C:/", "main.lua"), "C:/main.lua", "drive root join")
    assertEqual(path.join("//server/share", "main.lua"), "//server/share/main.lua", "UNC root join")
    assertEqual(path.join("/tmp/base", "\\\\server\\share\\main.lua"),
        "//server/share/main.lua", "backslash UNC right operand")
    assert(path.isWithin("foo/bar", "."))
    assert(path.isWithin("/foo", "/"))
    assert(path.isWithin("C:/foo", "C:/"))
    assert(path.isWithin("//server/share/foo", "//server/share"))
    assert(not path.isWithin("//server/other/foo", "//server/share"))
    assert(not path.isWithin("../foo", "."))
    assertEqual(path.relativeWithin("/tmp/base/a/b.lua", "/tmp/base"),
        "a/b.lua", "POSIX relative descendant")
    assertEqual(path.relativeWithin("C:/base/a.lua", "C:/base"),
        "a.lua", "drive relative descendant")
    assertEqual(path.relativeWithin("//server/share/a.lua", "//server/share"),
        "a.lua", "UNC relative descendant")
    assert(path.relativeWithin("/tmp/base", "/tmp/base") == nil)
    assert(path.relativeWithin("/tmp/other/a.lua", "/tmp/base") == nil)
    assert(not path.isSafeRelative("C:relative"))
    assert(not path.isSafeRelative("trailing/"))
    assert(not path.isSafeRelative("a//b"))
    assert(path.isSafeRelative("a/b.lua"))
    assert(path.isDriveRelative("C:relative"))
    assert(path.isDriveRelative("C:"))
    assert(not path.isDriveRelative("C:/absolute"))
    assertEqual(path.absolute("C:relative"), "C:relative", "drive-relative absolute conversion")
    assertEqual(path.join("/tmp", "C:relative"), "C:relative", "drive-relative join")
end)

test("public path options reject drive-relative names", function()
    local luainstaller = require("luainstaller")
    local entry = "test/single_file/01_hello_luainstaller.lua"
    local cases = {
        { option = "entry", opts = { entry = "C:main.lua" } },
        { option = "include", opts = { entry = entry, include = { "D:module.lua" } } },
        { option = "out", opts = { entry = entry, out = "E:bundle" } },
        { option = "lua_prefix", opts = { entry = entry, lua_prefix = "F:lua54" } },
        { option = "lua", opts = { entry = entry, lua = "G:lua.exe" } },
    }
    for _, case in ipairs(cases) do
        local result = luainstaller.analyze(case.opts)
        assert(not result.ok, case.option .. " drive-relative name was accepted")
        assertEqual(result.error.type, "InvalidOptionsError", case.option .. " drive-relative type")
        assertEqual(result.error.option, case.option, case.option .. " drive-relative option")
    end
    local child = harness.loader_prelude() .. [[
local result = require("luainstaller").analyze({
    entry = "test/single_file/01_hello_luainstaller.lua",
})
assert(not result.ok and result.error.type == "InvalidOptionsError")
assert(result.error.option == "lua_prefix")
print("drive-relative environment rejected")
]]
    local output = runCommand("LUAI_LUA_PREFIX=" .. shellQuote("H:lua54")
        .. " " .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("drive-relative environment rejected", 1, true))
end)

test("static native resolution prefers entry-rooted templates", function()
    local root = makeTempDir("entry-native-priority")
    local entry_dir = root .. "/entry"
    local host_dir = root .. "/host"
    makeDirectory(entry_dir)
    makeDirectory(host_dir)
    local entry = entry_dir .. "/main.lua"
    local entry_native = entry_dir .. "/priority.so"
    local host_native = host_dir .. "/priority.so"
    writeFile(entry, "return require('priority')\n")
    writeFile(entry_native, "entry native bytes\n")
    writeFile(host_native, "host native bytes\n")

    local original_cpath = package.cpath
    package.cpath = host_dir .. "/?.so"
    local call_ok, inspected = pcall(function()
        local resolver = require("luainstaller.analyzer").ModuleResolver.new(entry_dir)
        return resolver:inspect("priority", entry)
    end)
    package.cpath = original_cpath

    assert(call_ok, inspected)
    assert(inspected.ok and inspected.type == "native", "native fixture did not resolve")
    assertEqual(inspected.path, require("luainstaller.path").absolute(entry_native), "native resolution priority")
    removeTree(root)
end)

test("API rejects non-file and non-finite inputs", function()
    local luainstaller = require("luainstaller")
    local entry_directory = luainstaller.analyze({ entry = "test" })
    assert(not entry_directory.ok)
    assertEqual(entry_directory.error.type, "ScriptNotFoundError", "directory entry")

    local infinite = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        max_deps = math.huge,
    })
    assert(not infinite.ok)
    assertEqual(infinite.error.type, "InvalidOptionsError", "infinite max_deps")

    local nan = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        max_deps = 0 / 0,
    })
    assert(not nan.ok)
    assertEqual(nan.error.type, "InvalidOptionsError", "NaN max_deps")

    local default_target = luainstaller.compatibility({
        entry = "test/single_file/01_hello_luainstaller.lua",
    })
    local empty_target = luainstaller.compatibility({
        entry = "test/single_file/01_hello_luainstaller.lua",
        target_os = "",
    })
    assert(default_target.ok and empty_target.ok, "empty target_os compatibility failed")
    assertEqual(
        empty_target.compatibility.target.os,
        default_target.compatibility.target.os,
        "empty target_os default"
    )
end)

test("native platform and toolchain reject cross targets", function()
    local platform = require("luainstaller.platform")
    local host = platform.detectHost()
    local native, native_err = platform.profile({ target_os = host.os })
    assert(native, native_err and native_err.error and native_err.error.message)
    assertEqual(native.target_os, host.os, "native target OS")
    assertEqual(native.target_arch, platform.normalizeArch(host.arch), "native target architecture")

    local generic = assert(platform.profile({
        host = { os = "freebsd", arch = "x86_64" },
        target_os = "freebsd",
    }))
    assertEqual(generic.launcher_profile, "shared-lua", "generic POSIX launcher")
    assert(require("luainstaller.path").validateTargetRelative(
        "native/module.so",
        "freebsd"
    ))

    local cross_os = host.os == "windows" and "linux" or "windows"
    local cross, cross_err = platform.profile({ target_os = cross_os })
    assert(cross == nil, "cross target profile was accepted")
    assert(cross_err and cross_err.error.type == "UnsupportedPlatformError")

    local root = makeTempDir("native-target")
    local out = root .. "/out"
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
        target_os = cross_os,
    })
    assert(not result.ok)
    assertEqual(result.error.type, "UnsupportedPlatformError", "cross target API")
    assert(not fileExists(out), "cross target mutated its output")
    removeTree(root)

    local toolchain = require("luainstaller.toolchain")
    local resolved, resolve_err = toolchain.resolve({
        target_os = host.os,
        lua_version = require("luainstaller.compat").luaVersion(),
    })
    local failure_messages = {}
    for _, failure in ipairs(resolve_err and resolve_err.error
        and resolve_err.error.failures or {}) do
        failure_messages[#failure_messages + 1] = tostring(failure.message)
            .. ": " .. tostring(failure.output or "")
    end
    assert(resolved, resolve_err and resolve_err.error
        and (resolve_err.error.message .. "\n" .. table.concat(failure_messages, "\n")))
    assertEqual(resolved.host.os, host.os, "toolchain host OS")
    assertEqual(resolved.lua_version.abi,
        require("luainstaller.compat").luaVersion().abi, "toolchain Lua ABI")
    assert(type(resolved.cc) == "string" and resolved.cc ~= "")
end)

test("native runtime profiles reject incompatible Lua library kinds", function()
    local native_profile = require("luainstaller.native_profile")

    assert(native_profile.acceptsLibrary(
        { target_os = "linux", launcher_profile = "shared-lua" },
        "/prefix/lib/liblua.so"
    ))
    assert(native_profile.acceptsLibrary(
        { target_os = "linux", launcher_profile = "shared-lua" },
        "/prefix/lib/liblua.so.5.4"
    ))
    assert(not native_profile.acceptsLibrary(
        { target_os = "linux", launcher_profile = "shared-lua" },
        "/prefix/lib/liblua.a"
    ))
    assert(native_profile.acceptsLibrary(
        { target_os = "macos", launcher_profile = "static-lua" },
        "/prefix/lib/liblua.a"
    ))
    assert(not native_profile.acceptsLibrary(
        { target_os = "macos", launcher_profile = "static-lua" },
        "/prefix/lib/liblua.dylib"
    ))
    assert(native_profile.acceptsLibrary(
        { target_os = "windows", launcher_profile = "windows-shared-lua" },
        "C:/prefix/lua54.dll"
    ))
    assert(native_profile.acceptsLibrary(
        { target_os = "windows", launcher_profile = "windows-shared-lua" },
        "C:/prefix/lua54.lib"
    ))
    assert(not native_profile.acceptsLibrary(
        { target_os = "windows", launcher_profile = "windows-shared-lua" },
        "C:/prefix/liblua.a"
    ))
end)

test("Windows 1.0 platform profile is x86_64 only", function()
    local platform = require("luainstaller.platform")
    local supported = assert(platform.profile({
        host = { os = "windows", arch = "x86_64" },
        target_os = "windows",
    }))
    assertEqual(supported.target_arch, "x86_64", "Windows supported architecture")

    for _, arch in ipairs({ "x86", "arm64" }) do
        local profile, profile_err = platform.profile({
            host = { os = "windows", arch = arch },
            target_os = "windows",
        })
        assert(profile == nil, "Windows profile accepted unsupported " .. arch)
        assert(profile_err and profile_err.error.type == "UnsupportedPlatformError")
    end
end)

test("Windows release toolchains close the CRT on x86_64", function()
    local toolchain_source = readFile("src/toolchain.lua")
    local matrix_source = readFile("tools/test-lua-versions.ps1")

    assert(toolchain_source:find('"/MT"', 1, true),
        "product MSVC commands do not select the static CRT")
    assert(not toolchain_source:find('"/MD"', 1, true),
        "product MSVC commands retain the dynamic CRT")
    assert(toolchain_source:find('"/MACHINE:X64"', 1, true),
        "product MSVC linker commands do not pin x86_64")
    assert(matrix_source:find("'/MT'", 1, true),
        "Windows Lua matrix does not select the static CRT")
    assert(not matrix_source:find("'/MD'", 1, true),
        "Windows Lua matrix retains the dynamic CRT")
    assert(matrix_source:find("Assert-PeClosure", 1, true),
        "Windows matrix does not audit PE dependencies")
    assert(matrix_source:find("VCRUNTIME", 1, true),
        "Windows matrix does not reject the VC runtime DLL")
    assert(not matrix_source:find("Hostx64\\ARM64", 1, true),
        "Windows matrix contains an ARM64 compiler path")
end)

test("Linux explicit prefixes reject static-only liblua before compilation", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end

    local root = makeTempDir("linux-static-profile")
    makeDirectory(root .. "/include")
    makeDirectory(root .. "/lib")
    writeFile(root .. "/include/lua.h", "/* profile filter fixture */\n")
    writeFile(root .. "/lib/liblua.a", "not consulted by the compiler\n")

    local config, config_err = require("luainstaller.toolchain").resolve({
        lua_prefix = root,
        lua_version = require("luainstaller.compat").luaVersion(),
    })
    assert(config == nil, "Linux accepted a static-only explicit Lua prefix")
    assert(config_err and config_err.error.type == "ToolchainError")
    assert(tostring(config_err.error.cause):find("shared liblua", 1, true),
        tostring(config_err.error.cause))
    removeTree(root)
end)

test("API rejects unsafe string and manual include inputs", function()
    local luainstaller = require("luainstaller")
    local root = makeTempDir("input-validation")
    local text_path = root .. "/notes.txt"
    writeFile(text_path, "not Lua source\n")

    local include_directory = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        include = { root },
    })
    assert(not include_directory.ok)
    assertEqual(include_directory.error.type, "InvalidOptionsError", "directory include")

    local include_text = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        include = { text_path },
    })
    assert(not include_text.ok)
    assertEqual(include_text.error.type, "InvalidOptionsError", "non-Lua include")

    local nul_output = luainstaller.bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/bad\0output",
    })
    assert(not nul_output.ok)
    assertEqual(nul_output.error.type, "InvalidOptionsError", "NUL output")
    assert(not fileExists(root .. "/bad"))

    local control_output = luainstaller.bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/bad\nparent/output",
    })
    assert(not control_output.ok)
    assertEqual(control_output.error.type, "InvalidOptionsError", "control-byte output")
    assert(not fileExists(root .. "/bad\nparent"))

    local nul_argument = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        run_args = { "bad\0argument" },
    })
    assert(not nul_argument.ok)
    assertEqual(nul_argument.error.type, "InvalidOptionsError", "NUL run argument")

    removeTree(root)
end)

test("API rejects character devices as entry scripts", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local luainstaller = require("luainstaller")
    local result = luainstaller.analyze({ entry = "/dev/null" })
    assert(not result.ok)
    assertEqual(result.error.type, "ScriptNotFoundError", "device entry")
end)

test("require lexer matches legal Lua literal forms", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    local cases = {
        {
            name = "quoted basic",
            source = "local value = require 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "line comment before argument",
            source = "local value = require -- comment\n 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "block comment before argument",
            source = "local value = require --[=[ comment ]=] 'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "comment inside parentheses",
            source = "local value = require( -- comment\n 'foo')",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "pcall comments",
            source = "local ok, value = pcall( -- first\n require, -- second\n 'foo')",
            expected = { { name = "foo", line = 2, optional = true } },
        },
        {
            name = "form feed whitespace",
            source = "local value = require\f'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "vertical tab whitespace",
            source = "local value = require\v'foo'",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "long string initial newline",
            source = "local value = require [=[\nfoo]=]",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "long string CRLF normalization",
            source = "local value = require [=[\r\nfoo\r\nbar]=]",
            expected = { { name = "foo\nbar", line = 1 } },
        },
        {
            name = "escaped newline line tracking",
            source = "local a = require 'fo\\\no'\nlocal b = require 'bar'",
            expected = {
                { name = "fo\no", line = 1 },
                { name = "bar", line = 3 },
            },
        },
        {
            name = "result concatenation",
            source = "local value = require 'foo' .. suffix",
            expected = { { name = "foo", line = 1 } },
        },
        {
            name = "vararg before require",
            source = "local first = ...\nrequire 'foo'",
            expected = { { name = "foo", line = 2 } },
        },
    }

    for _, case in ipairs(cases) do
        assert(loadText(case.source, "=" .. case.name, {}), case.name)
        local actual = LuaLexer.new(case.source, case.name):extractRequires()
        assertEqual(#actual, #case.expected, case.name .. " count")
        for index, expected in ipairs(case.expected) do
            assertEqual(actual[index].name, expected.name, case.name .. " name")
            assertEqual(actual[index].line, expected.line, case.name .. " line")
            assertEqual(actual[index].optional == true, expected.optional == true, case.name .. " optional")
        end
    end
end)

test("static bundle includes a require after a vararg expression", function()
    local root = makeTempDir("vararg-require")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    writeFile(entry, [[
local first = ...
require("dependency")
assert(ELLIPSIS_DEPENDENCY == 73)
assert(first == nil or type(first) == "string")
]])
    writeFile(dependency, "ELLIPSIS_DEPENDENCY = 73\n")

    local bundled = require("luainstaller").bundle({
        entry = entry,
        out = root .. "/out",
    })
    assert(bundled.ok, bundled.error and bundled.error.message)
    runCommand(shellQuote(bundled.executable))
    removeTree(root)
end)

test("require lexer ignores identifier references and declarations", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    local sources = {
        "local saved = require; return saved",
        "if require then return true end",
        "local function require(name) return name end",
        "function require(name) return name end",
        "require = function(name) return name end",
        "local a, require = 1, function() end",
        "function consume(require) return require end",
        "local function pcall(require, name) return require, name end",
        "function pcall(require, name) return require, name end",
        "return object.require('foo')",
        "return object:require('foo')",
        "return object . require ('foo')",
        "return object : require ('foo')",
        "function object . require(name) return name end",
        "return object . pcall(require, 'foo')",
    }
    for _, source in ipairs(sources) do
        assert(loadText(source, "=reference", {}), source)
        local actual = LuaLexer.new(source, "reference.lua"):extractRequires()
        assertEqual(#actual, 0, source)
    end
end)

test("require lexer rejects computed call arguments", function()
    local LuaLexer = require("luainstaller.analyzer").LuaLexer
    for _, source in ipairs({
        "return require(name)",
        "return require('foo' .. suffix)",
        "return pcall(require, name)",
        "return pcall(require, 'foo' .. suffix)",
    }) do
        assert(loadText(source, "=computed", {}), source)
        local ok, err = pcall(function()
            return LuaLexer.new(source, "computed.lua"):extractRequires()
        end)
        assert(not ok, source)
        assert(type(err) == "table" and err.type == "DynamicRequireError", source)
    end
end)

test("invalid Lua never produces a bundle", function()
    local root = makeTempDir("invalid-lua")
    local entry = root .. "/main.lua"
    local out = root .. "/out"
    writeFile(entry, "local broken =")

    local luainstaller = require("luainstaller")
    local analyzed = luainstaller.analyze({ entry = entry })
    assert(not analyzed.ok)
    assertEqual(analyzed.error.type, "LuaSyntaxError", "analyze syntax error")

    local bundled = luainstaller.bundle({ entry = entry, out = out })
    assert(not bundled.ok)
    assertEqual(bundled.error.type, "LuaSyntaxError", "bundle syntax error")
    assert(not fileExists(out))

    removeTree(root)
end)

test("manual include syntax is validated", function()
    local root = makeTempDir("invalid-include")
    local included = root .. "/broken.lua"
    writeFile(included, "return function(")
    local result = require("luainstaller").analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        discovery_mode = "manual",
        include = { included },
    })
    assert(not result.ok)
    assertEqual(result.error.type, "LuaSyntaxError", "include syntax error")
    removeTree(root)
end)

test("BOM and shebang normalization preserves source lines", function()
    local analyzer = require("luainstaller.analyzer")
    local runtime = require("luainstaller.runtime")
    local source = "\239\187\191#!/usr/bin/env lua require('not-a-module')\r\nreturn 7"
    local prepared = analyzer.prepareSource(source)
    assertEqual(prepared:sub(1, 1), "\n", "prepared shebang newline")
    assert(loadText(prepared, "=prepared", {}))
    assertEqual(#analyzer.LuaLexer.new(source, "shebang.lua"):extractRequires(), 0, "shebang requires")
    assertEqual(runtime.stripSource(source):sub(1, 1), "\n", "runtime shebang newline")
end)

test("bit32 resolution follows the selected Lua ABI", function()
    local root = makeTempDir("bit32-module")
    local entry = root .. "/main.lua"
    local module = root .. "/bit32.lua"
    writeFile(entry, "return require('bit32')")
    writeFile(module, "return { external = true }")
    local result = require("luainstaller").analyze({ entry = entry })
    assert(result.ok, result.error and result.error.message)
    local current = assert(require("luainstaller.lua_abi").current())
    if require("luainstaller.lua_abi").isBuiltin(current, "bit32") then
        assertEqual(#result.dependencies.scripts, 0,
            "built-in bit32 dependency count for Lua " .. current)
    else
        assertEqual(#result.dependencies.scripts, 1,
            "external bit32 dependency count for Lua " .. current)
        assertEqual(result.dependencies.scripts[1], module,
            "external bit32 dependency path for Lua " .. current)
    end
    removeTree(root)
end)

test("runtime discovery uses the real loader path", function()
    local root = makeTempDir("runtime-loader")
    local entry_dir = root .. "/entry"
    local alt_dir = root .. "/alt"
    makeDirectory(entry_dir)
    makeDirectory(alt_dir)
    writeFile(entry_dir .. "/choice.lua", "return 'entry'\n")
    writeFile(alt_dir .. "/choice.lua", "return 'alt'\n")
    writeFile(entry_dir .. "/consumer.lua", "local value = require('choice')\nreturn value\n")
    writeFile(entry_dir .. "/main.lua", string.format(
        "package.path = %q .. package.path\nassert(require('choice') == 'alt')\nassert(require('consumer') == 'alt')\n",
        alt_dir .. "/?.lua;"
    ))

    local analyzed = require("luainstaller").analyze({
        entry = entry_dir .. "/main.lua",
        discovery_mode = "runtime",
    })
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    assertEqual(#analyzed.dependencies.scripts, 2, "runtime dependency count")
    local dependency_set = {}
    for _, dependency in ipairs(analyzed.dependencies.scripts) do
        dependency_set[dependency] = true
    end
    assert(dependency_set[alt_dir .. "/choice.lua"], "actual loader path missing")
    assert(dependency_set[entry_dir .. "/consumer.lua"], "consumer loader path missing")
    assert(not dependency_set[entry_dir .. "/choice.lua"], "cached require used a false fallback path")
    local identity = analyzed.dependencies.discovery
        and analyzed.dependencies.discovery.interpreter
    assert(type(identity) == "table", "verified interpreter identity is missing")
    assertEqual(
        identity.abi,
        assert(require("luainstaller.lua_abi").current()),
        "verified interpreter ABI"
    )
    assert(type(identity.path) == "string" and identity.path ~= "",
        "verified interpreter path is missing")
    local built_manifest = require("luainstaller.manifest").build({
        entry = entry_dir .. "/main.lua",
        dependencies = analyzed.dependencies,
        trace = analyzed.trace,
        discovery = analyzed.dependencies.discovery,
        source_hashes = analyzed.dependencies.source_hashes,
    })
    assert(built_manifest.ok, built_manifest.error and built_manifest.error.message)
    assertEqual(
        built_manifest.manifest.discovery.interpreter.abi,
        identity.abi,
        "manifest discovery ABI"
    )
    assertEqual(
        built_manifest.manifest.discovery.interpreter.command,
        require("luainstaller.path").basename(identity.path),
        "manifest stable interpreter command"
    )
    local trace = analyzed.trace[1]
    assertEqual(trace.selected_path, alt_dir .. "/choice.lua", "trace loader path")

    removeTree(root)
end)

test("runtime discovery rejects a module rewritten after loading", function()
    local root = makeTempDir("runtime-source-snapshot")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local late_dependency = root .. "/late.lua"
    writeFile(dependency, "return 41\n")
    writeFile(late_dependency, "return 99\n")
    writeFile(entry, string.format([[
assert(require("dependency") == 41)
local out = assert(io.open(%q, "wb"))
assert(out:write("return require('late')\n"))
assert(out:close())
]], dependency))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted bytes it did not execute")
    assertEqual(analyzed.error.type, "SourceChangedError", "runtime source snapshot")
    removeTree(root)
end)

test("runtime discovery rejects filesystem modules cached before tracing", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cached-module")
    local entry = root .. "/main.lua"
    local cached = root .. "/cached.lua"
    local helper = root .. "/helper.lua"
    local init = root .. "/init.lua"
    local wrapper = root .. "/lua-with-init"
    writeFile(cached, "return require('helper')\n")
    writeFile(helper, "return 73\n")
    writeFile(entry, string.format([[
local out = assert(io.open(%q, "wb"))
assert(out:write("return 99\n"))
assert(out:close())
assert(require('cached') == 73)
]], cached))
    writeFile(init, string.format(
        "package.path = %q .. package.path\nrequire('cached')\n",
        root .. "/?.lua;"
    ))
    writeFile(wrapper, table.concat({
        "#!/bin/sh",
        "LUA_INIT=" .. shellQuote("@" .. init),
        "export LUA_INIT",
        "exec " .. shellQuote(commandOutputTrimmed("command -v lua")) .. " \"$@\"",
        "",
    }, "\n"))
    runCommand("chmod 700 " .. shellQuote(wrapper))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
        lua = wrapper,
    })
    assert(not analyzed.ok, "runtime discovery accepted an unsnapshotted cached module")
    assertEqual(analyzed.error.type, "DiscoveryError", "cached runtime module")
    removeTree(root)
end)

test("runtime discovery rejects builtin names cached before tracing", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cached-builtin")
    local entry = root .. "/main.lua"
    local init = root .. "/init.lua"
    local wrapper = root .. "/lua-with-init"
    writeFile(entry, "assert(require('math') == 88)\n")
    writeFile(init, "package.loaded.math = 88\n")
    writeFile(wrapper, table.concat({
        "#!/bin/sh",
        "LUA_INIT=" .. shellQuote("@" .. init),
        "export LUA_INIT",
        "exec " .. shellQuote(commandOutputTrimmed("command -v lua")) .. " \"$@\"",
        "",
    }, "\n"))
    runCommand("chmod 700 " .. shellQuote(wrapper))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
        lua = wrapper,
    })
    assert(not analyzed.ok, "runtime discovery accepted a builtin replaced before tracing")
    assertEqual(analyzed.error.type, "DiscoveryError", "cached builtin runtime module")
    removeTree(root)
end)

test("runtime discovery rejects a filesystem fallback for a preload loader", function()
    local root = makeTempDir("runtime-preload-shadow")
    local entry = root .. "/main.lua"
    writeFile(root .. "/shadow.lua", "return 99\n")
    writeFile(entry, [[
package.preload.shadow = function() return 41 end
assert(require("shadow") == 41)
]])

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery substituted a file for a preload loader")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime preload fallback")
    removeTree(root)
end)

test("runtime discovery rejects custom native loader paths", function()
    local root = makeTempDir("runtime-native-snapshot")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    writeFile(native, "native bytes that returned 41\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        return function() return 41 end, %q
    end
    return "\n\tno fixture module " .. tostring(name)
end)
assert(require("swap") == 41)
local out = assert(io.open(%q, "wb"))
assert(out:write("replacement bytes that return 99\n"))
assert(out:close())
]], native, native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes it did not execute")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime custom native loader")
    removeTree(root)
end)

test("runtime discovery rejects a C loader without loader data", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-native-no-loader-data")
    local entry = root .. "/main.lua"
    local native = root .. "/shadow.so"
    local native_source = root .. "/shadow.c"
    writeFile(native_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_shadow(lua_State *state) { lua_pushinteger(state, 88); return 1; }
]])
    compileNativeFixture(native_source, native)
    writeFile(entry, string.format([[
package.loaded.math = nil
table.insert(package.searchers, 1, function(name)
    if name == "math" then
        return assert(package.loadlib(%q, "luaopen_shadow"))
    end
    return "\n\tfixture searcher miss"
end)
assert(require("math") == 88)
]], native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted a C loader without provenance")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime C loader without data")
    removeTree(root)
end)

test("runtime discovery rejects a loader from a searcher inserted during require", function()
    local root = makeTempDir("runtime-inserted-searcher")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
package.loaded.math = nil
local searchers = package.searchers
table.insert(searchers, 1, function(name)
    if name == "math" then
        table.insert(searchers, 2, function(inserted_name)
            if inserted_name == "math" then
                return function() return 88 end
            end
            return "\n\tinserted searcher miss"
        end)
    end
    return "\n\tinserting searcher miss"
end)
assert(require("math") == 88)
]])

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted an unwrapped loader without provenance")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime inserted searcher")
    removeTree(root)
end)

test("runtime discovery rejects a loader with a substituted environment", function()
    local root = makeTempDir("runtime-loader-environment")
    local entry = root .. "/main.lua"
    local dependency = root .. "/choice.lua"
    writeFile(dependency, "return VALUE\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "choice" then
        return assert(loadfile(%q, "t", { VALUE = 99 })), %q
    end
    return "\n\tfixture searcher miss"
end)
assert(require("choice") == 99)
]], dependency, dependency))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted a non-reproducible loader environment")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime loader environment")
    removeTree(root)
end)

test("runtime discovery rejects native paths changed inside a searcher", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-native-pre-snapshot")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    local replacement = root .. "/swap-new.so"
    writeFile(native, "native bytes mapped by the searcher\n")
    writeFile(replacement, "replacement bytes on disk\n")
    writeFile(entry, string.format([[
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        assert(os.rename(%q, %q))
        return function() return 41 end, %q
    end
    return "\n\tno fixture module " .. tostring(name)
end)
assert(require("swap") == 41)
]], replacement, native, native))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes changed inside a searcher")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime native searcher mutation")
    removeTree(root)
end)

test("runtime discovery rejects a native loader ABA during dlopen", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-native-aba")
    local entry = root .. "/main.lua"
    local active = root .. "/swap.so"
    local backup = root .. "/swap-original.so"
    local replacement = root .. "/swap-replacement.so"
    local original_source = root .. "/swap-original.c"
    local replacement_source = root .. "/swap-replacement.c"
    writeFile(original_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 41); return 1; }
]])
    writeFile(replacement_source, string.format([[
#include <stdio.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
__attribute__((constructor)) static void restore_original_path(void) {
    if (rename(%q, %q) != 0) _exit(90);
}
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 99); return 1; }
]], backup, active))
    compileNativeFixture(original_source, active)
    compileNativeFixture(replacement_source, replacement)
    writeFile(entry, string.format([[
package.cpath = %q .. package.cpath
table.insert(package.searchers, 1, function(name)
    if name == "swap" then
        assert(os.rename(%q, %q))
        assert(os.rename(%q, %q))
    end
    return "\n\tfixture searcher miss"
end)
assert(require("swap") == 99)
]], root .. "/?.so;", active, backup, replacement, active))

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not analyzed.ok, "runtime discovery accepted native bytes that were not executed")
    assertEqual(analyzed.error.type, "DiscoveryError", "runtime native ABA")
    removeTree(root)
end)

test("runtime bundle rejects native modules without provable executed bytes", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("runtime-real-native-rejection")
    local entry = root .. "/main.lua"
    local native = root .. "/swap.so"
    local native_source = root .. "/swap.c"
    writeFile(native_source, [[
#include <lua.h>
#include <lauxlib.h>
int luaopen_swap(lua_State *state) { lua_pushinteger(state, 41); return 1; }
]])
    compileNativeFixture(native_source, native)
    writeFile(entry, string.format([[
package.cpath = %q .. package.cpath
assert(require("swap") == 41)
]], root .. "/?.so;"))

    local bundled = require("luainstaller").bundle({
        entry = entry,
        out = root .. "/out",
        discovery_mode = "runtime",
    })
    assert(not bundled.ok, "runtime bundle accepted an unverifiable native loader")
    assertEqual(bundled.error.type, "DiscoveryError", "real runtime native loader")
    assert(bundled.error.message:find("static discovery", 1, true),
        table.concat({
            "native rejection is not actionable: " .. tostring(bundled.error.message),
            tostring(bundled.error.output or ""),
        }, "\n"))
    assert(not fileExists(root .. "/out"), "rejected runtime bundle published output")
    removeTree(root)
end)

test("runtime discovery rejects a non-official Lua interpreter", function()
    if not commandSucceeds("command -v luajit >/dev/null 2>&1") then
        return
    end
    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        discovery_mode = "runtime",
        lua = "luajit",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "ToolchainError", "runtime interpreter ABI")
end)

test("runtime discovery rejects a different official Lua ABI", function()
    if package.config:sub(1, 1) ~= "/" then return end

    local lua_abi = require("luainstaller.lua_abi")
    local active_abi = assert(lua_abi.current())
    local wrong_abi = active_abi == "5.4" and "5.3" or "5.4"
    local lua_binary = commandOutputTrimmed("command -v lua")
    assert(lua_binary ~= "", "cannot locate the active Lua interpreter")

    local root = makeTempDir("runtime-cross-abi")
    local wrapper = root .. "/lua-wrong-abi"
    writeFile(wrapper, string.format([=[#!/bin/sh
if [ "$1" = "-e" ]; then
    printf 'Lua %s'
    exit 0
fi
exec %s "$@"
]=], wrong_abi, shellQuote(lua_binary)))
    runCommand("chmod 700 " .. shellQuote(wrapper))

    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        discovery_mode = "runtime",
        lua = wrapper,
        run_args = { "cross-abi" },
    })
    assert(not result.ok, "runtime discovery accepted a different Lua ABI")
    assertEqual(result.error.type, "ToolchainError", "cross-ABI interpreter type")
    assertEqual(result.error.expected_abi, active_abi, "cross-ABI expected ABI")
    assertEqual(result.error.actual_abi, wrong_abi, "cross-ABI actual ABI")
    removeTree(root)
end)

test("runtime discovery rejects an incomplete trace", function()
    local root = makeTempDir("runtime-incomplete-trace")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
local original_open = io.open
io.open = function(path, mode)
    if mode ~= "wb" then return original_open(path, mode) end
    local actual = assert(original_open(path, mode))
    local proxy = {}
    function proxy:write() return self end
    function proxy:close() return actual:close() end
    return proxy
end
return true
]])
    local result = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "DiscoveryError", "partial runtime trace")
    removeTree(root)
end)

test("runtime discovery rejects a duplicate completion marker", function()
    local root = makeTempDir("runtime-duplicate-completion")
    local entry = root .. "/main.lua"
    writeFile(entry, [[
local original_open = io.open
io.open = function(path, mode)
    if mode ~= "wb" then return original_open(path, mode) end
    local actual = assert(original_open(path, mode))
    local proxy = {}
    function proxy:write(...)
        local values = packValues(...)
        assert(actual:write(unpackValues(values, 1, values.n)))
        if values[1] == "LUAINSTALLER_TRACE_V4_COMPLETE" then
            assert(actual:write(unpackValues(values, 1, values.n)))
        end
        return self
    end
    function proxy:flush() return actual:flush() end
    function proxy:close() return actual:close() end
    return proxy
end
return true
]])
    local result = require("luainstaller").analyze({
        entry = entry,
        discovery_mode = "runtime",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "DiscoveryError", "duplicate runtime completion")
    removeTree(root)
end)

test("runtime discovery reports temporary directory cleanup failures", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("runtime-cleanup-failure")
    local success_entry = root .. "/success.lua"
    local failure_entry = root .. "/failure.lua"
    writeFile(success_entry, "return true\n")
    writeFile(failure_entry, "error('injected trace failure')\n")

    local process = require("luainstaller.process")
    local original_output = process.output
    local cleanup_paths = {}
    process.output = function(command)
        if command:match("^rm %-rf ")
            and command:find("luainstaller%-require%-trace%-") then
            local cleanup_path = command:match("^rm %-rf '([^']+)'$")
            cleanup_paths[#cleanup_paths + 1] = cleanup_path
            return false, "injected trace cleanup failure"
        end
        return original_output(command)
    end
    local loaded, isolated_discovery = pcall(dofile, "src/discovery.lua")
    assert(loaded, isolated_discovery)

    local successful_plan, cleanup_err = isolated_discovery.plan({
        entry = success_entry,
        discovery_mode = "runtime",
    })
    local failed_plan, trace_err = isolated_discovery.plan({
        entry = failure_entry,
        discovery_mode = "runtime",
    })
    process.output = original_output
    for _, cleanup_path in ipairs(cleanup_paths) do
        if cleanup_path then runCommand("rm -rf " .. shellQuote(cleanup_path)) end
    end

    assert(#cleanup_paths == 2, "runtime cleanup failure injection did not cover both traces")
    assert(not successful_plan, "runtime discovery ignored cleanup failure after success")
    assertEqual(cleanup_err.error.type, "FilesystemError", "runtime cleanup error")
    assert(cleanup_err.error.path:find("luainstaller%-require%-trace%-"))
    assert(not failed_plan, "runtime discovery accepted a failed trace")
    assertEqual(trace_err.error.type, "DiscoveryError", "runtime trace primary error")
    assertEqual(trace_err.error.cleanup_error, "Cannot remove runtime trace directory", "cleanup detail")
    assert(trace_err.error.cleanup_path:find("luainstaller%-require%-trace%-"))
    removeTree(root)
end)

test("runtime run restores bundled module cache entries and all returns", function()
    local runtime = require("luainstaller.runtime")
    local searchers = package.searchers or package.loaders
    local searcher_count = #searchers
    local payload = {
        entry = {
            path = "edge-main.lua",
            source = "local value=require('edge_cache'); return value, nil, 23",
        },
        modules = {
            edge_cache = {
                path = "edge-cache.lua",
                source = "return 17",
            },
        },
    }

    package.loaded.edge_cache = "outer"
    local returned = packValues(runtime.run(payload))
    assertEqual(returned.n, 3, "return count")
    assertEqual(returned[1], 17, "bundled module value")
    assertEqual(returned[2], nil, "middle nil")
    assertEqual(returned[3], 23, "last return")
    assertEqual(package.loaded.edge_cache, "outer", "existing cache value")
    assertEqual(#searchers, searcher_count, "searcher count")

    package.loaded.edge_cache = nil
    assertEqual(runtime.run(payload), 17, "nil cache payload value")
    assertEqual(package.loaded.edge_cache, nil, "nil cache restored")

    package.loaded.edge_cache = false
    local failing = {
        entry = {
            path = "edge-failure.lua",
            source = "require('edge_cache'); error('edge failure')",
        },
        modules = payload.modules,
    }
    local ok = pcall(runtime.run, failing)
    assert(not ok)
    assertEqual(package.loaded.edge_cache, false, "false cache restored after error")
    assertEqual(#searchers, searcher_count, "searcher count after error")
    package.loaded.edge_cache = nil
end)

test("generated runtime restores module cache and return values", function()
    local root = makeTempDir("generated-runtime-state")
    local entry = root .. "/main.lua"
    local module = root .. "/edge_cache.lua"
    writeFile(entry, "local value=require('edge_cache'); return value, nil, 31\n")
    writeFile(module, "return 29\n")
    local cgen = require("luainstaller.cgen")
    local bootstrap = cgen.generateBootstrap({
        entry = entry,
        dependencies = { scripts = { module }, libraries = {} },
        module_names = { [module] = "edge_cache" },
    })
    local chunk = assert(loadText(bootstrap, "@generated-runtime-state", _G))
    package.loaded.edge_cache = "outer-generated"
    local returned = packValues(chunk())
    assertEqual(returned.n, 3, "generated return count")
    assertEqual(returned[1], 29, "generated bundled value")
    assertEqual(returned[2], nil, "generated middle nil")
    assertEqual(returned[3], 31, "generated last return")
    assertEqual(package.loaded.edge_cache, "outer-generated", "generated cache restored")
    package.loaded.edge_cache = nil
    removeTree(root)
end)

test("one source supports every required alias", function()
    for _, mode in ipairs({ "onedir", "onefile" }) do
        for order_index, order in ipairs({ { "pkg", "pkg.init" }, { "pkg.init", "pkg" } }) do
            local root = makeTempDir("alias-" .. mode .. "-" .. tostring(order_index))
            makeDirectory(root .. "/pkg")
            writeFile(root .. "/pkg/init.lua", "return { value = 19 }\n")
            writeFile(root .. "/main.lua", string.format([[
local first = require(%q)
local second = require(%q)
assert(first.value == 19 and second.value == 19)
]], order[1], order[2]))

            local result = require("luainstaller").bundle({
                entry = root .. "/main.lua",
                mode = mode,
                out = root .. "/out",
            })
            assert(result.ok, result.error and result.error.message)
            runCommand(shellQuote(result.executable))
            removeTree(root)
        end
    end
end)

test("Lua and native sources cannot own the same module alias", function()
    local root = makeTempDir("cross-kind-module-alias")
    local entry_dir = root .. "/entry"
    local manual_dir = root .. "/manual"
    makeDirectory(entry_dir)
    makeDirectory(manual_dir)
    local entry = entry_dir .. "/main.lua"
    local native = entry_dir .. "/collision.so"
    local lua_module = manual_dir .. "/collision.lua"
    writeFile(entry, "return require('collision')\n")
    writeFile(native, "not a real native module\n")
    writeFile(lua_module, "return 42\n")

    local result = require("luainstaller").bundle({
        entry = entry,
        include = { lua_module },
        out = root .. "/out",
    })
    assert(not result.ok, "cross-kind module alias was accepted")
    assertEqual(result.error.type, "DuplicateModuleError", "cross-kind alias")
    assertEqual(result.error.module_name, "collision", "cross-kind alias name")
    assert(not fileExists(root .. "/out"), "cross-kind alias published an output")
    removeTree(root)
end)

test("static discovery preserves every alias for one native source", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("native-alias")
    makeDirectory(root .. "/pkg")
    writeFile(root .. "/module.c", [[
#include <lua.h>
#include <lauxlib.h>

static int open_alias(lua_State *L) {
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, 37);
    lua_setfield(L, -2, "value");
    return 1;
}

int luaopen_pkg(lua_State *L) { return open_alias(L); }
int luaopen_pkg_init(lua_State *L) { return open_alias(L); }
]])
    compileNativeFixture(root .. "/module.c", root .. "/pkg/init.so")
    writeFile(root .. "/main.lua", [[
local first = require("pkg")
local second = require("pkg.init")
assert(first.value == 37 and second.value == 37)
]])

    local result = require("luainstaller").bundle({
        entry = root .. "/main.lua",
        out = root .. "/out",
        discovery_mode = "static",
    })
    assert(result.ok, result.error and result.error.message)
    runCommand(shellQuote(result.executable))
    assert(fileExists(root .. "/out/.luai/native/pkg.so"))
    assert(fileExists(root .. "/out/.luai/native/pkg/init.so"))
    removeTree(root)
end)

test("Lua runtime cannot overwrite a native module destination", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local runtime_name, runtime_path = selectedLinuxRuntime()
    assert(runtime_name and runtime_path,
        "cannot identify the selected Lua runtime collision fixture")

    local root = makeTempDir("native-runtime-collision")
    local entry = root .. "/main.lua"
    local collision = root .. "/" .. runtime_name
    local out = root .. "/out"
    writeFile(entry, "return true\n")
    runCommand("cp " .. shellQuote(runtime_path) .. " " .. shellQuote(collision))
    local dependencies = { scripts = {}, libraries = { collision }, trace = {} }
    local built_manifest = require("luainstaller.manifest").build({
        entry = entry,
        mode = "onedir",
        out = out,
        target_os = "linux",
        dependencies = dependencies,
    })
    assert(built_manifest.ok, built_manifest.error and built_manifest.error.message)
    local result = require("luainstaller.bundler").bundleOnedir({
        entry = entry,
        out = out,
        target_os = "linux",
        dependencies = dependencies,
        manifest = built_manifest.manifest,
    })
    assert(not result.ok, "Lua runtime overwrote a native module destination")
    assertEqual(result.error.type, "DuplicateModuleError", "Lua runtime destination collision")
    assert(not fileExists(out .. "/out"), "collision build published an executable")
    removeTree(root)
end)

test("manual init include exposes package aliases", function()
    local root = makeTempDir("manual-init-alias")
    makeDirectory(root .. "/pkg")
    writeFile(root .. "/pkg/init.lua", "return { value = 43 }\n")
    writeFile(root .. "/main.lua", [[
assert(require("pkg").value == 43)
assert(require("pkg.init").value == 43)
]])
    local result = require("luainstaller").bundle({
        entry = root .. "/main.lua",
        out = root .. "/out",
        depscan = false,
        include = { root .. "/pkg/init.lua" },
    })
    assert(result.ok, result.error and result.error.message)
    runCommand(shellQuote(result.executable))
    removeTree(root)
end)

test("external manual init include uses its parent package name", function()
    local root = makeTempDir("external-manual-init-alias")
    local app = root .. "/app"
    local package_dir = root .. "/vendor/pkg"
    makeDirectory(app)
    makeDirectory(root .. "/vendor")
    makeDirectory(package_dir)
    local entry = app .. "/main.lua"
    local included = package_dir .. "/init.lua"
    writeFile(entry, "return true\n")
    writeFile(included, "return { value = 47 }\n")

    local analyzed = require("luainstaller").analyze({
        entry = entry,
        depscan = false,
        include = { included },
    })
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    local aliases = {}
    for _, item in ipairs(analyzed.trace) do
        if item.selected_path == included then aliases[item.requested] = true end
    end
    assert(aliases.pkg, "external init.lua lacks its package alias")
    assert(aliases["pkg.init"], "external init.lua lacks its explicit init alias")
    assert(not aliases.init and not aliases["init.init"], "external init.lua used generic aliases")
    removeTree(root)
end)

test("manual include deduplicates an automatic dependency", function()
    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        include = { "test/runtime_bundle/greeter.lua" },
    })
    assert(result.ok, result.error and result.error.message)
    assertEqual(#result.dependencies.scripts, 1, "canonical include count")
end)

test("Source changed during compiler execution is rejected", function()
    local root = makeTempDir("source-changed")
    local fake_bin = root .. "/bin"
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local out = root .. "/out"
    makeDirectory(fake_bin)
    writeFile(entry, "assert(require('dependency').value == 41)\n")
    writeFile(dependency, "return { value = 41 }\n")
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
printf '%s\n' 'return { value = 99 }' > "$LUAI_MUTATE_SOURCE"
exec "$LUAI_REAL_CC" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/cc"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = %q,
    out = %q,
})
assert(result.ok == false, "source mutation must fail the build")
assert(result.error.type == "SourceChangedError", result.error.type)
assert(io.open(%q, "rb") == nil, "failed build must not publish output")
]], entry, out, out)
    local real_cc = commandOutputTrimmed("command -v cc")
    runCommand(table.concat({
        "LUAI_MUTATE_SOURCE=" .. shellQuote(dependency),
        "LUAI_REAL_CC=" .. shellQuote(real_cc),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    removeTree(root)
end)

test("Source changed before embedding is rejected", function()
    local root = makeTempDir("source-changed-before-embed")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local out = root .. "/out"
    writeFile(entry, "assert(require('dependency').value == 41)\n")
    writeFile(dependency, "return { value = 41 }\n")

    local manifest = require("luainstaller.manifest")
    local original_build = manifest.build
    manifest.build = function(opts)
        local built = original_build(opts)
        if built.ok then
            writeFile(dependency, "return { value = 99 }\n")
        end
        return built
    end
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = entry,
        out = out,
    })
    manifest.build = original_build

    assert(call_ok, result)
    assert(not result.ok)
    assertEqual(result.error.type, "SourceChangedError", "pre-embed mutation")
    assert(not fileExists(out .. "/out"), "failed build published an executable")
    removeTree(root)
end)

test("Source changed between discovery and manifest creation is rejected", function()
    local root = makeTempDir("source-changed-after-discovery")
    local entry = root .. "/main.lua"
    local dependency = root .. "/dependency.lua"
    local late_dependency = root .. "/late.lua"
    writeFile(entry, "return require('dependency')\n")
    writeFile(dependency, "return 41\n")
    writeFile(late_dependency, "return 99\n")

    local manifest = require("luainstaller.manifest")
    local bundler = require("luainstaller.bundler")
    local original_manifest_build = manifest.build
    local original_bundle_onedir = bundler.bundleOnedir
    local bundler_called = false
    manifest.build = function(opts)
        writeFile(entry, "return require('late')\n")
        return original_manifest_build(opts)
    end
    bundler.bundleOnedir = function()
        bundler_called = true
        return { ok = true }
    end

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = entry,
        out = root .. "/out",
    })
    manifest.build = original_manifest_build
    bundler.bundleOnedir = original_bundle_onedir

    assert(call_ok, result)
    assert(not result.ok, "post-discovery source mutation must fail the build")
    assertEqual(result.error.type, "SourceChangedError", "post-discovery mutation")
    assert(not bundler_called, "unsafe manifest reached the bundler")
    removeTree(root)
end)

test("output ownership is recursive and exact", function()
    local root = makeTempDir("recursive-output-owner")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local user_data = out .. "/.luai/USER-DATA.txt"
    writeFile(user_data, "must survive\n")
    local extra = require("luainstaller").bundle(opts)
    assert(not extra.ok and extra.error.type == "InvalidOutputError")
    assertEqual(readFile(user_data), "must survive\n", "nested user content")
    assert(os.remove(user_data))

    local user_dir = out .. "/.luai/unowned-empty-directory"
    makeDirectory(user_dir)
    local extra_dir = require("luainstaller").bundle(opts)
    assert(not extra_dir.ok and extra_dir.error.type == "InvalidOutputError")
    runCommand("test -d " .. shellQuote(user_dir))
    runCommand("rmdir " .. shellQuote(user_dir))

    local manifest_path = out .. "/.luai/manifest.lua"
    local original_manifest = readFile(manifest_path)
    writeFile(manifest_path, original_manifest .. "-- tampered\n")
    local changed = require("luainstaller").bundle(opts)
    assert(not changed.ok and changed.error.type == "InvalidOutputError")
    assertEqual(readFile(manifest_path), original_manifest .. "-- tampered\n", "tampered manifest")
    writeFile(manifest_path, original_manifest)

    local launcher_path = out .. "/.luai/build/launcher.c"
    local launcher_source = readFile(launcher_path)
    assert(os.remove(launcher_path))
    local missing = require("luainstaller").bundle(opts)
    assert(not missing.ok and missing.error.type == "InvalidOutputError")
    assert(not fileExists(launcher_path), "missing generated file was recreated")
    writeFile(launcher_path, launcher_source)

    if package.config:sub(1, 1) == "/" then
        local link_path = out .. "/.luai/unowned-link"
        runCommand("ln -s " .. shellQuote(manifest_path) .. " " .. shellQuote(link_path))
        local linked = require("luainstaller").bundle(opts)
        assert(not linked.ok and linked.error.type == "InvalidOutputError")
        runCommand("test -L " .. shellQuote(link_path))
        assert(os.remove(link_path))

        local fifo_path = out .. "/.luai/unowned-fifo"
        runCommand("mkfifo " .. shellQuote(fifo_path))
        local fifo = require("luainstaller").bundle(opts)
        assert(not fifo.ok and fifo.error.type == "InvalidOutputError")
        runCommand("test -p " .. shellQuote(fifo_path))
        assert(os.remove(fifo_path))
    end

    local rebuilt = require("luainstaller").bundle(opts)
    assert(rebuilt.ok, rebuilt.error and rebuilt.error.message)
    removeTree(root)
end)

test("POSIX output ownership rejects backslash path aliases", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-backslash-alias")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local user_path = out .. "/.luai\\manifest.lua"
    writeFile(user_path, "user data must survive\n")
    local rebuilt = require("luainstaller").bundle(opts)
    assert(not rebuilt.ok, "backslash alias bypassed the exact output inventory")
    assertEqual(rebuilt.error.type, "InvalidOutputError", "backslash alias output")
    assertEqual(readFile(user_path), "user data must survive\n", "backslash alias user data")
    removeTree(root)
end)

test("output changed during the final rename window is restored", function()
    local root = makeTempDir("output-final-rename-race")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_rename = os.rename
    local injected = false
    rawset(os, "rename", function(from, to)
        if not injected and from == out and tostring(to):find(".luai-backup-", 1, true) then
            injected = true
            writeFile(out .. "/USER-DATA.txt", "must survive final rename race\n")
        end
        return original_rename(from, to)
    end)
    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "final output rename hook did not run")
    assert(not rebuilt.ok, "output changed in the final rename window was replaced")
    assertEqual(rebuilt.error.type, "InvalidOutputError", "final rename race")
    assertEqual(
        readFile(out .. "/USER-DATA.txt"),
        "must survive final rename race\n",
        "final rename race user data"
    )
    runCommand(shellQuote(first.executable))
    removeTree(root)
end)

test("output changed after publication is restored before backup deletion", function()
    local root = makeTempDir("output-backup-delete-race")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_rename = os.rename
    local backup_path
    local injected = false
    rawset(os, "rename", function(from, to)
        if from == out and tostring(to):find(".luai-backup-", 1, true) then
            backup_path = to
        end
        local values = packValues(original_rename(from, to))
        if values[1] and not injected and to == out
            and tostring(from):find(".luai-staging-", 1, true) then
            assert(backup_path, "backup path was not observed")
            injected = true
            writeFile(backup_path .. "/USER-DATA.txt", "must survive backup cleanup race\n")
        end
        return unpackValues(values, 1, values.n)
    end)
    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "published output rename hook did not run")
    assert(not rebuilt.ok, "backup changed before deletion was discarded")
    assertEqual(rebuilt.error.type, "InvalidOutputError", "backup cleanup race")
    assertEqual(
        readFile(out .. "/USER-DATA.txt"),
        "must survive backup cleanup race\n",
        "backup cleanup race user data"
    )
    runCommand(shellQuote(first.executable))
    removeTree(root)
end)

test("backup cleanup never recursively removes late user content", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-backup-late-content")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_popen = io.popen
    local original_remove = os.remove
    local backup_path
    local injected = false
    local user_content = "late user content must survive\n"
    local function inject(candidate)
        if injected then return end
        injected = true
        backup_path = candidate:match("^(.*%.luai%-backup%-[^/]+)") or candidate
        writeFile(backup_path .. "/USER-DATA.txt", user_content)
    end
    rawset(io, "popen", function(command, mode)
        local candidate = command:match("^rm %-rf '([^']+%.luai%-backup%-[^']+)' 2>&1$")
        if candidate then inject(candidate) end
        return original_popen(command, mode)
    end)
    rawset(os, "remove", function(candidate)
        if type(candidate) == "string" and candidate:find("%.luai%-backup%-") then
            inject(candidate)
        end
        return original_remove(candidate)
    end)

    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(io, "popen", original_popen)
    rawset(os, "remove", original_remove)

    assert(call_ok, rebuilt)
    assert(injected, "backup cleanup hook did not run")
    assert(not rebuilt.ok, "late backup content was recursively discarded")
    assertEqual(rebuilt.error.type, "FilesystemError", "late backup cleanup")
    assertEqual(readFile(backup_path .. "/USER-DATA.txt"), user_content, "late backup user data")
    runCommand(shellQuote(rebuilt.executable or out .. "/out"))
    removeTree(root)
end)

test("backup cleanup preserves a late replacement at an owned name", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-backup-owned-replacement")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_remove = os.remove
    local original_rename = os.rename
    local injected = false
    local replaced_path
    local user_content = "replacement bytes must survive\n"
    local function isOwnedBackupName(candidate)
        return type(candidate) == "string"
            and candidate:find("%.luai%-backup%-")
            and not candidate:find("%.luai%-remove%-")
    end
    rawset(os, "remove", function(candidate)
        if not injected and isOwnedBackupName(candidate) and fileExists(candidate) then
            injected = true
            replaced_path = candidate
            assert(original_rename(candidate, candidate .. ".old-generated"))
            writeFile(candidate, user_content)
        end
        return original_remove(candidate)
    end)
    rawset(os, "rename", function(from, to)
        if not injected and isOwnedBackupName(from)
            and type(to) == "string" and to:find("%.luai%-remove%-") then
            local values = packValues(original_rename(from, to))
            if values[1] then
                injected = true
                replaced_path = from
                writeFile(from, user_content)
            end
            return unpackValues(values, 1, values.n)
        end
        return original_rename(from, to)
    end)

    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "remove", original_remove)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "owned-name replacement hook did not run")
    assert(not rebuilt.ok, "build ignored a replacement inside its backup")
    assertEqual(readFile(replaced_path), user_content, "owned-name replacement bytes")
    removeTree(root)
end)

test("backup cleanup never unlinks a directory-name file replacement", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-backup-directory-replacement")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(opts)
    assert(first.ok, first.error and first.error.message)

    local original_remove = os.remove
    local original_rename = os.rename
    local original_popen = io.popen
    local injected = false
    local replaced_path
    local user_content = "directory-name replacement must survive\n"
    local function isTarget(candidate)
        return type(candidate) == "string"
            and candidate:find("%.luai%-backup%-")
            and candidate:match("/%.luai/native$") ~= nil
    end
    local function replaceDirectory(candidate)
        if injected then return end
        injected = true
        replaced_path = candidate
        assert(original_rename(candidate, candidate .. ".old-generated-directory"))
        writeFile(candidate, user_content)
    end
    rawset(os, "remove", function(candidate)
        if isTarget(candidate) then replaceDirectory(candidate) end
        return original_remove(candidate)
    end)
    rawset(io, "popen", function(command, mode)
        local candidate = command:match("rmdir '([^']+)'", 1)
        if isTarget(candidate) then replaceDirectory(candidate) end
        return original_popen(command, mode)
    end)

    local call_ok, rebuilt = pcall(luainstaller.bundle, opts)
    rawset(os, "remove", original_remove)
    rawset(io, "popen", original_popen)
    rawset(os, "rename", original_rename)

    assert(call_ok, rebuilt)
    assert(injected, "backup directory replacement hook did not run")
    assert(not rebuilt.ok, "build ignored a file replacement at a directory name")
    assertEqual(readFile(replaced_path), user_content, "backup directory-name replacement")
    removeTree(root)
end)

test("empty backup cleanup never unlinks a regular-file replacement", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-empty-backup-replacement")
    local out = root .. "/out"
    makeDirectory(out)
    local original_remove = os.remove
    local original_rename = os.rename
    local original_popen = io.popen
    local injected = false
    local backup_path
    local user_content = "empty-backup replacement must survive\n"
    local function isTarget(candidate)
        return type(candidate) == "string"
            and candidate:find("%.luai%-backup%-") ~= nil
            and not candidate:find("/", #root + 2, true)
    end
    local function replaceDirectory(candidate)
        if injected then return end
        injected = true
        backup_path = candidate
        assert(original_rename(candidate, candidate .. ".old-empty-directory"))
        writeFile(candidate, user_content)
    end
    rawset(os, "remove", function(candidate)
        if isTarget(candidate) then replaceDirectory(candidate) end
        return original_remove(candidate)
    end)
    rawset(io, "popen", function(command, mode)
        local candidate = command:match("rmdir '([^']+)'", 1)
        if isTarget(candidate) then replaceDirectory(candidate) end
        return original_popen(command, mode)
    end)

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "remove", original_remove)
    rawset(io, "popen", original_popen)
    rawset(os, "rename", original_rename)

    assert(call_ok, result)
    assert(injected, "empty backup replacement hook did not run")
    assert(not result.ok, "build unlinked a replacement at the empty-backup path")
    assert(result.error and result.error.committed == true, "committed cleanup failure was not reported")
    assertEqual(readFile(backup_path), user_content, "empty backup replacement")
    removeTree(root)
end)

test("output lock release never removes a replacement lock", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-replacement")
    local out = root .. "/out"
    local replacement_content = "another build owns this lock\n"
    local original_rename = os.rename
    local replacement_lock
    local injected = false

    local function replaceLock(lock_path)
        assert(not injected, "lock replacement hook ran twice")
        injected = true
        replacement_lock = lock_path
        assert(original_rename(lock_path, lock_path .. ".original"))
        runCommand("mkdir -m 700 " .. shellQuote(lock_path))
        writeFile(lock_path .. "/OTHER-OWNER", replacement_content)
    end

    rawset(os, "rename", function(from, to)
        if not injected and type(from) == "string" and from:match("/%.luai%-lock%-%x+$")
            and type(to) == "string" and to:match("/%.luai%-lock%-release%-%x+$") then
            replaceLock(from)
        end
        return original_rename(from, to)
    end)

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "rename", original_rename)

    assert(call_ok, result)
    assert(injected, "lock release hook did not run")
    assert(not result.ok, "builder claimed success after its output lock was replaced")
    assert(result.error and result.error.committed == true,
        "post-publish lock failure was not marked committed")
    assert(fileExists(out .. "/out"), "post-publish lock failure removed the artifact")
    assertEqual(readFile(replacement_lock .. "/OTHER-OWNER"), replacement_content, "replacement lock owner")
    removeTree(root)
end)

test("build transaction finalizes a thrown compiler failure", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-transaction-throw")
    local out = root .. "/out"
    local toolchain = require("luainstaller.toolchain")
    local original_compile = toolchain.compile
    local injected = false

    toolchain.compile = function(...)
        injected = true
        error("forced compiler interruption", 0)
    end
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    toolchain.compile = original_compile

    local lock_path = root .. "/.luai-lock-"
        .. require("luainstaller.hash").sha256(out)
    local lock_absent = commandSucceeds("test ! -e " .. shellQuote(lock_path)
        .. " && test ! -L " .. shellQuote(lock_path))
    local staging_count = tonumber(commandOutputTrimmed(
        "find " .. shellQuote(root)
            .. " -mindepth 1 -maxdepth 1 -name '.luai-staging-*' -print | wc -l"
    ))
    removeTree(root)

    assert(injected, "compiler interruption hook did not run")
    assert(call_ok, "bundle leaked a thrown compiler failure: " .. tostring(result))
    assert(result and result.ok == false, "thrown compiler failure was not structured")
    assert(lock_absent, "interrupted build left its output lock")
    assertEqual(staging_count, 0, "interrupted build staging count")
end)

test("build transaction finalizes thrown staging and publish failures", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local fs = require("luainstaller.fs")
    local hash = require("luainstaller.hash")
    for _, point in ipairs({ "staging", "publish" }) do
        local root = makeTempDir("output-transaction-" .. point)
        local out = root .. "/out"
        local lock_path = root .. "/.luai-lock-" .. hash.sha256(out)
        local original_create = fs.createDirectory
        local original_rename = os.rename
        local injected = false

        if point == "staging" then
            fs.createDirectory = function(candidate, ...)
                if not injected and tostring(candidate):find("/.luai-staging-", 1, true) then
                    injected = true
                    error("forced staging interruption", 0)
                end
                return original_create(candidate, ...)
            end
        else
            rawset(os, "rename", function(from, to)
                if not injected and tostring(from):find("/.luai-staging-", 1, true)
                    and to == out then
                    injected = true
                    error("forced publish interruption", 0)
                end
                return original_rename(from, to)
            end)
        end

        local call_ok, result = pcall(require("luainstaller").bundle, {
            entry = "test/single_file/01_hello_luainstaller.lua",
            out = out,
        })
        fs.createDirectory = original_create
        rawset(os, "rename", original_rename)

        local lock_absent = commandSucceeds("test ! -e " .. shellQuote(lock_path)
            .. " && test ! -L " .. shellQuote(lock_path))
        local staging_count = tonumber(commandOutputTrimmed(
            "find " .. shellQuote(root)
                .. " -mindepth 1 -maxdepth 1 -name '.luai-staging-*' -print | wc -l"
        ))
        local output_absent = commandSucceeds("test ! -e " .. shellQuote(out)
            .. " && test ! -L " .. shellQuote(out))
        removeTree(root)

        assert(injected, point .. " interruption hook did not run")
        assert(call_ok, point .. " interruption escaped: " .. tostring(result))
        assert(result and result.ok == false, point .. " interruption was not structured")
        assert(lock_absent, point .. " interruption left a lock")
        assertEqual(staging_count, 0, point .. " interruption staging count")
        assert(output_absent,
            point .. " interruption published an output")
    end
end)

test("output lock owner publication failure leaves no anonymous lock", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local fs = require("luainstaller.fs")
    for _, mode in ipairs({ "return", "throw" }) do
        local root = makeTempDir("output-owner-write-" .. mode)
        local out = root .. "/out"
        local lock_path = root .. "/.luai-lock-"
            .. require("luainstaller.hash").sha256(out)
        local original_write = fs.writeFile
        local injected = false
        fs.writeFile = function(candidate, ...)
            if not injected and tostring(candidate):find("/.luai-lock-", 1, true)
                and tostring(candidate):find("/owner.", 1, true) then
                injected = true
                if mode == "throw" then error("forced owner write interruption", 0) end
                return nil, "forced owner write failure"
            end
            return original_write(candidate, ...)
        end
        local call_ok, result = pcall(require("luainstaller").bundle, {
            entry = "test/single_file/01_hello_luainstaller.lua",
            out = out,
        })
        fs.writeFile = original_write
        local lock_absent = commandSucceeds("test ! -e " .. shellQuote(lock_path)
            .. " && test ! -L " .. shellQuote(lock_path))
        removeTree(root)
        assert(injected, mode .. " owner-write hook did not run")
        assert(call_ok, mode .. " owner-write failure escaped: " .. tostring(result))
        assert(result and not result.ok, mode .. " owner-write failure was not reported")
        assert(lock_absent,
            mode .. " owner-write failure left an anonymous lock")
    end
end)

test("build recovers an unchanged dead-owner lock and staging tree", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-dead-owner")
    local out = root .. "/out"
    local lock_hash = require("luainstaller.hash").sha256(out)
    local token = string.rep("a", 64)
    local lock_path = root .. "/.luai-lock-" .. lock_hash
    local stage_path = root .. "/.luai-staging-" .. lock_hash:sub(1, 24) .. "-" .. token
    local owner_content = assert(require("luainstaller.lock_owner").encode({
        token = token,
        pid = "99999999",
        created = os.time() - 60,
        output_hash = lock_hash,
        staging = stage_path:match("[^/]+$"),
    }))
    makeDirectory(lock_path)
    writeFile(lock_path .. "/owner." .. token, owner_content)
    makeDirectory(stage_path)
    writeFile(stage_path .. "/.luai-staging-owner." .. token, owner_content)
    writeFile(stage_path .. "/partial", "abandoned compiler output\n")

    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    local stale_stage_absent = commandSucceeds("test ! -e " .. shellQuote(stage_path)
        .. " && test ! -L " .. shellQuote(stage_path))
    local lock_absent = commandSucceeds("test ! -e " .. shellQuote(lock_path)
        .. " && test ! -L " .. shellQuote(lock_path))
    local artifact_exists = fileExists(out .. "/out")
    removeTree(root)

    assert(result.ok, result.error and result.error.message)
    assert(stale_stage_absent,
        "dead owner's staging tree remains")
    assert(lock_absent, "dead owner's output lock remains")
    assert(artifact_exists, "retry did not publish an artifact")
end)

test("build never steals live or malformed output locks", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local lock_owner = require("luainstaller.lock_owner")
    local hash = require("luainstaller.hash")
    for _, kind in ipairs({ "live", "malformed" }) do
        local root = makeTempDir("output-lock-" .. kind)
        local out = root .. "/out"
        local lock_hash = hash.sha256(out)
        local lock_path = root .. "/.luai-lock-" .. lock_hash
        local token = string.rep(kind == "live" and "b" or "c", 64)
        local stage_name = ".luai-staging-" .. lock_hash:sub(1, 24) .. "-" .. token
        local owner_content
        if kind == "live" then
            owner_content = assert(lock_owner.encode({
                token = token,
                pid = assert(lock_owner.currentPid()),
                created = os.time() - 3600,
                output_hash = lock_hash,
                staging = stage_name,
            }))
        else
            owner_content = "version=1\ntoken=" .. token .. "\npid=not-a-pid\n"
        end
        makeDirectory(lock_path)
        writeFile(lock_path .. "/owner." .. token, owner_content)

        local result = require("luainstaller").bundle({
            entry = "test/single_file/01_hello_luainstaller.lua",
            out = out,
        })
        local preserved_owner = readFile(lock_path .. "/owner." .. token)
        removeTree(root)

        assert(not result.ok, kind .. " lock was stolen")
        assertEqual(preserved_owner, owner_content, kind .. " owner record")
    end
end)

test("build stale recovery preserves a replacement output lock", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-stale-aba")
    local out = root .. "/out"
    local hash = require("luainstaller.hash")
    local lock_owner = require("luainstaller.lock_owner")
    local lock_hash = hash.sha256(out)
    local lock_path = root .. "/.luai-lock-" .. lock_hash
    local stale_token = string.rep("d", 64)
    local replacement_token = string.rep("e", 64)
    local function encoded(token, pid)
        return assert(lock_owner.encode({
            token = token,
            pid = pid,
            created = os.time() - 60,
            output_hash = lock_hash,
            staging = ".luai-staging-" .. lock_hash:sub(1, 24) .. "-" .. token,
        }))
    end
    makeDirectory(lock_path)
    writeFile(lock_path .. "/owner." .. stale_token, encoded(stale_token, "99999999"))

    local replacement = encoded(replacement_token, assert(lock_owner.currentPid()))
    local original_rename = os.rename
    local injected = false
    rawset(os, "rename", function(from, to)
        if not injected and from == lock_path
            and tostring(to):find("/.luai-lock-stale-", 1, true) then
            injected = true
            assert(original_rename(lock_path, lock_path .. ".observed-stale"))
            runCommand("mkdir -m 700 " .. shellQuote(lock_path))
            writeFile(lock_path .. "/owner." .. replacement_token, replacement)
            writeFile(lock_path .. "/SENTINEL", "replacement must survive\n")
        end
        return original_rename(from, to)
    end)
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "rename", original_rename)

    local preserved_owner = readFile(lock_path .. "/owner." .. replacement_token)
    local preserved_sentinel = readFile(lock_path .. "/SENTINEL")
    removeTree(root)
    assert(call_ok, result)
    assert(injected, "stale-lock replacement hook did not run")
    assert(not result.ok, "build stole the replacement lock")
    assertEqual(preserved_owner, replacement, "replacement owner record")
    assertEqual(preserved_sentinel, "replacement must survive\n", "replacement sentinel")
end)

test("build recovers an old empty pre-publication lock", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-empty-stale")
    local out = root .. "/out"
    local lock_path = root .. "/.luai-lock-"
        .. require("luainstaller.hash").sha256(out)
    makeDirectory(lock_path)
    runCommand("touch -t 200001010000 " .. shellQuote(lock_path))
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    local artifact_exists = fileExists(out .. "/out")
    removeTree(root)
    assert(result.ok, result.error and result.error.message)
    assert(artifact_exists, "empty-lock recovery did not publish an artifact")
end)

test("build empty-lock recovery preserves a replacement directory", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-empty-aba")
    local out = root .. "/out"
    local lock_path = root .. "/.luai-lock-"
        .. require("luainstaller.hash").sha256(out)
    makeDirectory(lock_path)
    runCommand("touch -t 200001010000 " .. shellQuote(lock_path))
    local function identity(candidate)
        local process = require("luainstaller.process")
        return process.firstLine("stat -c '%d:%i' " .. shellQuote(candidate) .. " 2>/dev/null")
            or process.firstLine("stat -f '%d:%i' " .. shellQuote(candidate) .. " 2>/dev/null")
    end
    local original_rename = os.rename
    local replacement_identity
    local injected = false
    rawset(os, "rename", function(from, to)
        if not injected and from == lock_path
            and tostring(to):find("/.luai-lock-stale-", 1, true) then
            injected = true
            assert(original_rename(lock_path, lock_path .. ".observed-empty"))
            runCommand("mkdir -m 700 " .. shellQuote(lock_path))
            replacement_identity = identity(lock_path)
        end
        return original_rename(from, to)
    end)
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "rename", original_rename)
    local final_identity = identity(lock_path)
    removeTree(root)
    assert(call_ok, result)
    assert(injected, "empty-lock replacement hook did not run")
    assert(not result.ok, "build stole the replacement empty lock")
    assertEqual(final_identity, replacement_identity, "replacement empty-lock identity")
end)

test("internal bundle siblings support a near-NAME_MAX output basename", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-name-max")
    local out = root .. "/" .. string.rep("n", 240)
    local options = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local luainstaller = require("luainstaller")
    local first = luainstaller.bundle(options)
    assert(first.ok, first.error and first.error.message)
    local second = luainstaller.bundle(options)
    assert(second.ok, second.error and second.error.message)
    assert(fileExists(out .. "/" .. string.rep("n", 240)),
        "near-NAME_MAX bundle executable is missing")
    removeTree(root)
end)

test("output lock release never unlinks a regular-file replacement", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-file-replacement")
    local out = root .. "/out"
    local original_remove = os.remove
    local original_rename = os.rename
    local injected = false
    local replacement_lock
    local user_content = "replacement lock file must survive\n"

    rawset(os, "remove", function(candidate)
        if not injected and type(candidate) == "string"
            and candidate:find("%.luai%-lock") and candidate:find("/owner%.") then
            local values = packValues(original_remove(candidate))
            if values[1] then
                injected = true
                replacement_lock = candidate:match("^(.*)/owner%.")
                assert(original_rename(replacement_lock, replacement_lock .. ".original"))
                writeFile(replacement_lock, user_content)
            end
            return unpackValues(values, 1, values.n)
        end
        return original_remove(candidate)
    end)

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "remove", original_remove)
    rawset(os, "rename", original_rename)

    assert(call_ok, result)
    assert(injected, "lock-file replacement hook did not run")
    assert(not result.ok, "builder claimed success after unlinking a replacement lock file")
    assertEqual(readFile(replacement_lock), user_content, "replacement lock file")
    removeTree(root)
end)

test("output lock entropy failure occurs before lock publication", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-acquire-file-replacement")
    local out = root .. "/out"
    local original_open = io.open
    local lock_path = root .. "/.luai-lock-"
        .. require("luainstaller.hash").sha256(out)
    rawset(io, "open", function(path_value, mode)
        if path_value == "/dev/urandom" then
            return nil, "forced entropy failure"
        end
        return original_open(path_value, mode)
    end)
    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(io, "open", original_open)

    assert(call_ok, result)
    assert(not result.ok, "entropy failure was not reported")
    local absent = commandSucceeds("test ! -e " .. shellQuote(lock_path)
        .. " && test ! -L " .. shellQuote(lock_path))
    assert(absent, "entropy failure published a lock without ownership")
    removeTree(root)
end)

test("output lock release leaves a newly acquired empty lock untouched", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("output-lock-new-owner-window")
    local out = root .. "/out"
    local original_remove = os.remove
    local original_rename = os.rename
    local injected = false
    local replacement_lock

    rawset(os, "rename", function(from, to)
        if type(from) == "string" and from:match("/%.luai%-lock%-%x+$")
            and type(to) == "string" and to:match("/%.luai%-lock%-release%-%x+$") then
            replacement_lock = from
        end
        return original_rename(from, to)
    end)

    rawset(os, "remove", function(candidate)
        if not injected and type(candidate) == "string"
            and candidate:find("%.luai%-lock")
            and candidate:find("/owner%.") then
            local values = packValues(original_remove(candidate))
            if values[1] then
                injected = true
                assert(replacement_lock, "active lock path was not observed")
                runCommand("mkdir -m 700 " .. shellQuote(replacement_lock))
            end
            return unpackValues(values, 1, values.n)
        end
        return original_remove(candidate)
    end)

    local call_ok, result = pcall(require("luainstaller").bundle, {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    })
    rawset(os, "remove", original_remove)
    rawset(os, "rename", original_rename)

    assert(call_ok, result)
    assert(injected, "post-owner lock acquisition hook did not run")
    assert(result.ok, result.error and result.error.message)
    runCommand("test -d " .. shellQuote(replacement_lock))
    removeTree(root)
end)

test("output marker rejects malformed ownership records", function()
    local root = makeTempDir("malformed-output-marker")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local marker_path = out .. "/.luai/generated-output.txt"
    local original = readFile(marker_path)
    local inventory_record = original:match("\n(dir\t[^\n]+)\n")
        or original:match("\n(file\t[^\n]+)\n")
    assert(inventory_record)

    local malformed = {
        {
            name = "wrong output directory",
            content = original:gsub("output_dir=[^\n]+", "output_dir=/not/the/output", 1),
        },
        {
            name = "duplicate output directory",
            content = original .. "output_dir=" .. out .. "\n",
        },
        {
            name = "duplicate inventory record",
            content = original .. inventory_record .. "\n",
        },
        {
            name = "path traversal",
            content = original .. "dir\t../escape\n",
        },
        {
            name = "short digest",
            content = original .. "file\t.luai/short\tabcd\n",
        },
        {
            name = "marker self ownership",
            content = original .. "file\t.luai/generated-output.txt\t"
                .. string.rep("0", 64) .. "\n",
        },
        {
            name = "missing final newline",
            content = original:sub(1, -2),
        },
    }
    for _, case in ipairs(malformed) do
        writeFile(marker_path, case.content)
        local result = require("luainstaller").bundle(opts)
        assert(not result.ok and result.error.type == "InvalidOutputError", case.name)
        assertEqual(readFile(marker_path), case.content, case.name .. " preserved")
    end
    writeFile(marker_path, original)
    local rebuilt = require("luainstaller").bundle(opts)
    assert(rebuilt.ok, rebuilt.error and rebuilt.error.message)
    removeTree(root)
end)

test("legacy v1 output is never overwritten automatically", function()
    local root = makeTempDir("legacy-output")
    local out = root .. "/out"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local marker_path = out .. "/.luai/generated-output.txt"
    local legacy = readFile(marker_path):gsub(
        "^luainstaller%-generated%-output%-v%d+",
        "luainstaller-generated-output-v1"
    )
    writeFile(marker_path, legacy)

    local rebuilt = require("luainstaller").bundle(opts)
    assert(not rebuilt.ok and rebuilt.error.type == "InvalidOutputError")
    assertEqual(readFile(marker_path), legacy, "legacy marker")
    assert(fileExists(first.executable), "legacy executable must survive refusal")
    removeTree(root)
end)

test("manifest and output marker use v2 SHA-256 schema", function()
    local root = makeTempDir("v2-hash-schema")
    local out = root .. "/out"
    local result = require("luainstaller").bundle({
        entry = "test/runtime_bundle/main.lua",
        out = out,
    })
    assert(result.ok, result.error and result.error.message)
    assertEqual(result.manifest.version, 2, "manifest version")
    assertEqual(result.manifest.hash_algorithm, "sha256", "manifest hash algorithm")
    assert(result.manifest.entry.content_hash:match("^[0-9a-f]+$")
        and #result.manifest.entry.content_hash == 64)
    for _, group_name in ipairs({ "lua", "native", "external" }) do
        for _, item in ipairs(result.manifest.modules[group_name] or {}) do
            assert(item.content_hash:match("^[0-9a-f]+$") and #item.content_hash == 64)
        end
    end

    local marker = readFile(out .. "/.luai/generated-output.txt")
    assert(marker:match("^luainstaller%-generated%-output%-v2\n"))
    assert(marker:find("dir\t.luai/build\n", 1, true))
    assert(marker:find("file\t.luai/manifest.lua\t", 1, true))
    for line in marker:gmatch("[^\n]+") do
        local digest = line:match("^file\t[^\t]+\t([0-9a-f]+)$")
        if digest then assertEqual(#digest, 64, "marker SHA-256 length") end
    end
    removeTree(root)
end)

test("unreadable nonempty output is never classified empty", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("unreadable-output")
    local out = root .. "/out"
    makeDirectory(out)
    writeFile(out .. "/sentinel", "keep\n")
    runCommand("chmod 000 " .. shellQuote(out))
    local unreadable = commandSucceeds("test ! -r " .. shellQuote(out))
    if unreadable then
        local result = require("luainstaller").bundle({
            entry = "test/single_file/01_hello_luainstaller.lua",
            out = out,
        })
        runCommand("chmod 700 " .. shellQuote(out))
        assert(not result.ok)
        assertEqual(readFile(out .. "/sentinel"), "keep\n", "unreadable sentinel")
    else
        runCommand("chmod 700 " .. shellQuote(out))
    end
    removeTree(root)
end)

test("target paths reject Windows hazards and portable collisions", function()
    local path = require("luainstaller.path")
    local hazards = {
        "CON", "con.txt", "aux.txt", "NUL.lua", "PRN", "COM1", "com9.dll",
        "LPT1", "lpt9.txt", "CONIN$", "CONOUT$", "CLOCK$", "nested/AUX.log",
        "a:b", "C:relative", "C:/absolute", "trail.", "trail ", "nested/trail. ",
        "bad?.dll", "bad*.dll", "bad<name", "bad>name", "bad|name", 'bad"name',
        "control\1name", "delete\127name",
    }
    for _, value in ipairs(hazards) do
        local ok = path.validateTargetRelative(value, "windows")
        assert(not ok, "Windows target path accepted: " .. value)
    end
    for _, value in ipairs({ "normal.dll", "nested/Core-1.dll", "COM0", "COM10.dll" }) do
        local ok = path.validateTargetRelative(value, "windows")
        assert(ok, "Windows target path rejected: " .. value)
    end
    for _, target_os in ipairs({ "windows", "macos" }) do
        local ok = path.validateTargetRelative("native/Ä.so", target_os)
        assert(not ok, target_os .. " target accepted a path without reliable case folding")
    end
    assertEqual(
        path.targetKey("A/Core.dll", "windows"),
        path.targetKey("a/core.DLL", "windows"),
        "Windows target key"
    )
    assertEqual(
        path.targetKey("A/Core.dylib", "macos"),
        path.targetKey("a/core.DYLIB", "macos"),
        "macOS target key"
    )

    local root = makeTempDir("target-collisions")
    writeFile(root .. "/Core.dll", "first")
    writeFile(root .. "/core.DLL", "second")
    writeFile(root .. "/CON.dll", "reserved")
    local manifest = require("luainstaller.manifest")
    local platform = require("luainstaller.platform")
    local original_detect = platform.detectHost
    platform.detectHost = function() return { os = "windows", arch = "x86_64" } end
    local build_ok, duplicate, reserved = pcall(function()
        local duplicate_result = manifest.build({
            entry = "test/single_file/01_hello_luainstaller.lua",
            target_os = "windows",
            dependencies = {
                scripts = {},
                libraries = { root .. "/Core.dll", root .. "/core.DLL" },
            },
        })
        local reserved_result = manifest.build({
            entry = "test/single_file/01_hello_luainstaller.lua",
            target_os = "windows",
            dependencies = { scripts = {}, libraries = { root .. "/CON.dll" } },
        })
        return duplicate_result, reserved_result
    end)
    platform.detectHost = original_detect
    assert(build_ok, duplicate)
    assert(not duplicate.ok and duplicate.error.type == "DuplicateModuleError")
    assert(not reserved.ok and reserved.error.type == "InvalidOptionsError")
    removeTree(root)
end)

test("host mac defaults to static launcher profile and target metadata", function()
    local platform = require("luainstaller.platform")
    local manifest = require("luainstaller.manifest")
    local compat = require("luainstaller.compat")
    local original_detect = platform.detectHost
    platform.detectHost = function()
        return { os = "macos", arch = "arm64" }
    end
    local call_ok, built, diagnosed = pcall(function()
        local result = manifest.build({
            entry = "test/single_file/01_hello_luainstaller.lua",
            dependencies = { scripts = {}, libraries = {} },
        })
        return result, compat.diagnose({ dependencies = { libraries = {} } })
    end)
    platform.detectHost = original_detect
    assert(call_ok, built)
    assert(built.ok, built.error and built.error.message)
    assertEqual(built.manifest.launcher.profile, "static-lua", "mac launcher profile")
    assertEqual(built.manifest.platform.host.os, "macos", "manifest host OS")
    assertEqual(built.manifest.platform.host.arch, "arm64", "manifest host arch")
    assertEqual(built.manifest.platform.target.os, "macos", "manifest target OS")
    assertEqual(built.manifest.platform.target.arch, "arm64", "manifest target arch")
    assertEqual(diagnosed.target.launcher_profile, "static-lua", "compat launcher profile")
    assertEqual(diagnosed.target.arch, "arm64", "compat target arch")

    local lied = require("luainstaller").analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        launcher_profile = "not-a-real-profile",
    })
    assert(not lied.ok and lied.error.type == "InvalidOptionsError")
    assertEqual(lied.error.option, "launcher_profile", "launcher profile option")
end)

test("macOS bundle rejects a non-macOS build host", function()
    if commandOutputTrimmed("uname -s") == "Darwin" then return end
    local root = makeTempDir("macos-host-gate")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/out",
        target_os = "macos",
        lua_prefix = root .. "/not-a-prefix",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "UnsupportedPlatformError", "macOS build host gate")
    removeTree(root)
end)

test("unsafe output is rejected before platform and toolchain probes", function()
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = ".",
        lua_prefix = "/tmp/luainstaller-missing-lua-prefix",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "InvalidOutputError", "unsafe output validation order")
end)

test("an explicit Lua prefix never falls back to another toolchain", function()
    local root = makeTempDir("missing-explicit-lua-prefix")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/out",
        lua_prefix = root .. "/missing-prefix",
    })
    assert(not result.ok, "an invalid explicit Lua prefix was silently ignored")
    assertEqual(result.error.type, "ToolchainError", "explicit Lua prefix error")
    assert(tostring(result.error.message):find("Lua prefix", 1, true))
    assert(not fileExists(root .. "/out"), "invalid Lua prefix published an output")
    removeTree(root)
end)

test("Linux explicit prefixes support lib64 and contained runtime links", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end

    local fs = require("luainstaller.fs")
    local path = require("luainstaller.path")
    local compat = require("luainstaller.compat")
    local toolchain = require("luainstaller.toolchain")
    local lua_info = compat.luaVersion()
    local abi = string.format("%d.%d", lua_info.major, lua_info.minor)
    local matrix_prefix = os.getenv("LUAI_LUA_PREFIX")
    local include_source
    local runtime_source
    if type(matrix_prefix) == "string" and matrix_prefix ~= "" then
        include_source = path.join(matrix_prefix, "include")
        runtime_source = path.join(matrix_prefix, "lib/liblua.so." .. abi)
    else
        include_source = commandOutputTrimmed(
            "pkg-config --variable=includedir lua"
        )
        local lua_binary = commandOutputTrimmed("command -v lua")
        runtime_source = commandOutputTrimmed(
            "ldd " .. shellQuote(lua_binary)
                .. " | awk '/[Ll]ua/{print $3; exit}'"
        )
    end
    assert(include_source ~= "" and fs.isRegularFile(include_source .. "/lua.h"))
    assert(runtime_source ~= "" and fs.isRegularFile(runtime_source), runtime_source)

    local root = makeTempDir("linux-prefix-layouts")
    local function makePrefix(name, library_dir_name)
        local prefix = root .. "/" .. name
        makeDirectory(prefix)
        makeDirectory(prefix .. "/include")
        makeDirectory(prefix .. "/" .. library_dir_name)
        for _, header in ipairs({
            "lua.h", "luaconf.h", "lauxlib.h", "lualib.h", "lua.hpp",
        }) do
            local source = include_source .. "/" .. header
            if fs.isRegularFile(source) then
                assert(fs.copyFile(source, prefix .. "/include/" .. header))
            end
        end
        return prefix, prefix .. "/" .. library_dir_name
    end

    local lib64_prefix, lib64 = makePrefix("lib64-prefix", "lib64")
    local runtime_name = path.basename(runtime_source)
    assert(fs.copyFile(runtime_source, lib64 .. "/" .. runtime_name))
    local lib64_config, lib64_err = toolchain.resolve({
        lua_prefix = lib64_prefix,
        lua_version = lua_info,
    })
    assert(lib64_config, lib64_err and lib64_err.error.message)
    assertEqual(lib64_config.link_mode, "shared", "lib64 link mode")
    assert(lib64_config.runtime_path:sub(1, #lib64 + 1) == lib64 .. "/",
        "loader inspection escaped the explicit lib64 prefix: "
            .. tostring(lib64_config.runtime_path))

    local linked_prefix, linked_lib = makePrefix("linked-prefix", "lib")
    assert(fs.copyFile(runtime_source, linked_lib .. "/runtime-blob"))
    -- Preserve the runtime's loader identity. Renaming a shared object whose
    -- ELF SONAME differs makes the probe unlaunchable even when the symlink is
    -- otherwise safely contained.
    local linked_name = runtime_name
    runCommand("ln -s runtime-blob "
        .. shellQuote(linked_lib .. "/" .. linked_name))
    local linked_config, linked_err = toolchain.resolve({
        lua_prefix = linked_prefix,
        lua_version = lua_info,
    })
    local linked_diagnostic = {}
    if linked_err and linked_err.error then
        linked_diagnostic[#linked_diagnostic + 1] = linked_err.error.message
        for _, failure in ipairs(linked_err.error.failures or {}) do
            linked_diagnostic[#linked_diagnostic + 1] = tostring(failure.message)
                .. ": " .. tostring(failure.output or failure.cause or "")
        end
    end
    assert(linked_config, table.concat(linked_diagnostic, "\n"))
    assert(linked_config.runtime_path:sub(1, #linked_lib + 1) == linked_lib .. "/")
    assertEqual(linked_config.runtime_name, linked_name, "linked runtime identity")

    local linked_out = root .. "/linked-output"
    local linked_bundle = require("luainstaller").bundle({
        entry = "test/runtime_bundle/main.lua",
        out = linked_out,
        lua_prefix = linked_prefix,
    })
    assert(linked_bundle.ok, linked_bundle.error and linked_bundle.error.message)
    assert(fileExists(linked_out .. "/.luai/native/" .. linked_name),
        "bundle did not preserve the linked runtime loader name")
    local empty_path = root .. "/empty-path"
    makeDirectory(empty_path)
    local linked_ran, linked_output = require("luainstaller.process").outputCommand(
        linked_bundle.executable,
        { "linked-prefix" },
        { PATH = empty_path, LUA_PATH = "", LUA_CPATH = "" }
    )
    assert(linked_ran and linked_output:find("hello linked-prefix", 1, true),
        linked_output)

    local escaped_prefix, escaped_lib = makePrefix("escaped-prefix", "lib")
    runCommand("ln -s " .. shellQuote(runtime_source) .. " "
        .. shellQuote(escaped_lib .. "/liblua-" .. abi .. ".so"))
    local escaped, escaped_err = toolchain.resolve({
        lua_prefix = escaped_prefix,
        lua_version = lua_info,
    })
    assert(escaped == nil, "explicit prefix accepted an escaping runtime symlink")
    assert(escaped_err and escaped_err.error.type == "ToolchainError")

    removeTree(root)
end)

test("onedir rejects an executable collision with metadata directory", function()
    local root = makeTempDir("metadata-executable-collision")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/.luai",
    })
    assert(not result.ok)
    assertEqual(result.error.type, "InvalidOptionsError", "reserved onedir executable")
    assert(not fileExists(root .. "/.luai"), "reserved output was partially published")
    removeTree(root)
end)

test("pkg-config Lua ABI mismatch stops before compiler invocation", function()
    if package.config:sub(1, 1) ~= "/"
        or not commandSucceeds("command -v pkg-config >/dev/null 2>&1")
    then
        return
    end
    local root = makeTempDir("pkg-config-abi")
    local fake_bin = root .. "/bin"
    local compiler_marker = root .. "/compiler-called"
    local out = root .. "/out"
    local current_version = compat.luaVersion().version
    local mismatched_release = current_version == "Lua 5.4" and "5.3.6" or "5.4.8"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/pkg-config", string.format([[#!/bin/sh
if [ "$1" = "--modversion" ]; then
    printf '%%s\n' %q
    exit 0
fi
exec "$LUAI_REAL_PKG_CONFIG" "$@"
]], mismatched_release))
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
: > "$LUAI_COMPILER_MARKER"
exec "$LUAI_REAL_CC" "$@"
]])
    writeFile(fake_bin .. "/luarocks", "#!/bin/sh\nexit 2\n")
    writeFile(fake_bin .. "/lua-no-dev", "#!/bin/sh\nexit 2\n")
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/pkg-config")
        .. " " .. shellQuote(fake_bin .. "/cc")
        .. " " .. shellQuote(fake_bin .. "/luarocks")
        .. " " .. shellQuote(fake_bin .. "/lua-no-dev"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
})
assert(result.ok == false, %q)
assert(result.error.type == "ToolchainError", result.error.type)
assert(io.open(%q, "rb") == nil, "compiler was invoked before ABI rejection")
]], out, mismatched_release .. " pkg-config metadata must not match "
        .. current_version, compiler_marker)
    runCommand(table.concat({
        "LUAI_REAL_PKG_CONFIG=" .. shellQuote(commandOutputTrimmed("command -v pkg-config")),
        "LUAI_REAL_CC=" .. shellQuote(commandOutputTrimmed("command -v cc")),
        "LUAI_COMPILER_MARKER=" .. shellQuote(compiler_marker),
        "LUAI_LUA=" .. shellQuote(fake_bin .. "/lua-no-dev"),
        "LUAI_LUA_PREFIX=" .. shellQuote(""),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    assert(not fileExists(out .. "/out"), "ABI failure published an executable")
    removeTree(root)
end)

test("unsafe pkg-config flags fail closed before compiler discovery", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("pkg-config-unsafe-flags")
    local fake_bin = root .. "/bin"
    local compiler_marker = root .. "/compiler-called"
    local out = root .. "/out"
    local info = compat.luaVersion()
    local module_release = string.format("%d.%d.99", info.major, info.minor)
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/pkg-config", string.format([[#!/bin/sh
case "$1" in
    --version) printf '%%s\n' '1.9.5'; exit 0 ;;
    --modversion) printf '%%s\n' %s; exit 0 ;;
    --cflags) printf '%%s\n' '-I/tmp/lua-include;injected'; exit 0 ;;
esac
exit 2
]], shellQuote(module_release)))
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
: > "$LUAI_COMPILER_MARKER"
exit 2
]])
    writeFile(fake_bin .. "/luarocks", "#!/bin/sh\nexit 2\n")
    writeFile(fake_bin .. "/lua-no-dev", "#!/bin/sh\nexit 2\n")
    runCommand("chmod 700 " .. shellQuote(fake_bin .. "/pkg-config")
        .. " " .. shellQuote(fake_bin .. "/cc")
        .. " " .. shellQuote(fake_bin .. "/luarocks")
        .. " " .. shellQuote(fake_bin .. "/lua-no-dev"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
})
assert(result.ok == false, "unsafe pkg-config flags were accepted")
assert(result.error.type == "ToolchainError", result.error.type)
assert(result.error.message:find("unsafe characters", 1, true), result.error.message)
assert(result.error.token == "-I/tmp/lua-include;injected", tostring(result.error.token))
]], out)
    runCommand(table.concat({
        "LUAI_COMPILER_MARKER=" .. shellQuote(compiler_marker),
        "LUAI_LUA=" .. shellQuote(fake_bin .. "/lua-no-dev"),
        "LUAI_LUA_PREFIX=" .. shellQuote(""),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    assert(not fileExists(compiler_marker),
        "compiler discovery ran after unsafe pkg-config metadata")
    assert(not fileExists(out), "unsafe pkg-config metadata published output")
    removeTree(root)
end)

test("linked Lua runtime must report the selected ABI", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("linked-lua-abi")
    local fake_bin = root .. "/bin"
    local fake_lib = root .. "/lib"
    local stub_c = root .. "/lua-stub.c"
    local out = root .. "/out"
    local lua_info = compat.luaVersion()
    local real_toolchain, real_toolchain_err = require("luainstaller.toolchain").resolve({
        lua_prefix = os.getenv("LUAI_LUA_PREFIX"),
        lua_version = lua_info,
    })
    assert(real_toolchain, real_toolchain_err and real_toolchain_err.error.message)
    assertEqual(real_toolchain.link_mode, "shared", "ABI rejection fixture link mode")
    local misreported_version = lua_info.version == "Lua 5.3" and "Lua 5.4" or "Lua 5.3"
    makeDirectory(fake_bin)
    makeDirectory(fake_lib)
    writeFile(stub_c, string.format([[
#include <stddef.h>
typedef struct lua_State lua_State;
const char *lua_tolstring(lua_State *state, int index, size_t *size) {
    static const char version[] = %q;
    (void)state;
    (void)index;
    if (size) *size = sizeof(version) - 1;
    return version;
}
]], misreported_version))
    runCommand(table.concat({
        "cc -shared -fPIC",
        shellQuote(stub_c),
        "-Wl,-soname,liblua-fake.so",
        "-o",
        shellQuote(fake_lib .. "/liblua-fake.so"),
    }, " "))
    local fake_flags = table.concat({
        "-I" .. real_toolchain.include_dir,
        "-L" .. fake_lib,
        "-Wl,-rpath," .. fake_lib,
        "-llua-fake",
        real_toolchain.library_path,
        "-Wl,-rpath," .. real_toolchain.library_dir,
        "-lm",
        "-ldl",
    }, " ")
    writeFile(fake_bin .. "/pkg-config", string.format([[#!/bin/sh
if [ "$1" = "--version" ]; then
    printf '%%s\n' '1.9.5'
    exit 0
fi
if [ "$1" = "--modversion" ]; then
    printf '%%s\n' %s
    exit 0
fi
if [ "$1" = "--cflags" ]; then
    printf '%%s\n' %s
    exit 0
fi
exit 2
]], shellQuote(lua_info.version:match("(%d+%.%d+)") .. ".99"), shellQuote(fake_flags)))
    writeFile(fake_bin .. "/luarocks", "#!/bin/sh\nexit 2\n")
    runCommand("chmod 700 " .. shellQuote(fake_bin .. "/pkg-config")
        .. " " .. shellQuote(fake_bin .. "/luarocks"))

    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
})
assert(result.ok == false, "misreported linked Lua runtime was accepted")
assert(result.error.type == "ToolchainError", result.error.type)
assert(result.error.message:find("linked Lua runtime", 1, true), result.error.message)
local diagnostic = result.error.message
for _, failure in ipairs(result.error.failures or {}) do
    diagnostic = diagnostic .. "\n" .. tostring(failure.message)
        .. "\n" .. tostring(failure.output or "")
end
assert(diagnostic:find(%q, 1, true), diagnostic)
assert(diagnostic:find(%q, 1, true), diagnostic)
    ]], out, "expected " .. lua_info.version, "got " .. misreported_version)
    runCommand(table.concat({
        "LUAI_LUA_PREFIX=" .. shellQuote(""),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    assert(not fileExists(out .. "/out"), "ABI probe failure published an executable")
    removeTree(root)
end)

test("linked ABI probe cannot collide with the output executable", function()
    if commandOutputTrimmed("uname -s") ~= "Linux" then return end
    local root = makeTempDir("linked-abi-probe-name")
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        out = root .. "/lua-abi-probe",
    })
    assert(result.ok, result.error and result.error.message)
    assert(fileExists(result.executable), "ABI probe removed the output executable")
    runCommand(shellQuote(result.executable))
    removeTree(root)
end)

test("target launcher enforces the selected Lua ABI", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("launcher-abi-guard")
    local include_dir = root .. "/include"
    local c_path = root .. "/launcher.c"
    local log_path = root .. "/compiler.log"
    local selected_prefix = os.getenv("LUAI_LUA_PREFIX")
    local selected_include
    if selected_prefix and selected_prefix ~= "" then
        selected_include = selected_prefix .. "/include"
        assert(fileExists(selected_include .. "/lua.h"),
            "selected Lua prefix has no lua.h")
    elseif commandSucceeds("command -v pkg-config >/dev/null 2>&1") then
        selected_include = commandOutputTrimmed(
            "pkg-config --variable=includedir lua"
        )
    else
        removeTree(root)
        return
    end
    makeDirectory(include_dir)
    local lua_info = require("luainstaller.compat").luaVersion()
    local mismatched_num = lua_info.num == 501 and 502 or 501
    writeFile(include_dir .. "/lua.h", string.format([[
#include_next <lua.h>
#undef LUA_VERSION_NUM
#define LUA_VERSION_NUM %d
]], mismatched_num))
    local launcher = require("luainstaller.launcher")
    local generated = launcher.generateSource({
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
        lua_version = lua_info,
    })
    local source51 = launcher.generateSource({
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
        lua_version = { version = "Lua 5.1", major = 5, minor = 1, num = 501, abi = "lua5.1" },
    })
    local source55 = launcher.generateSource({
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
        lua_version = { version = "Lua 5.5", major = 5, minor = 5, num = 505, abi = "lua5.5" },
    })
    assert(generated:find("LUA_VERSION_NUM != " .. tostring(lua_info.num), 1, true))
    assert(source51:find("LUA_VERSION_NUM != 501", 1, true))
    assert(source51:find("Lua 5.1", 1, true))
    assert(source51:find("luaL_loadbuffer", 1, true))
    assert(source55:find("LUA_VERSION_NUM != 505", 1, true))
    assert(source55:find("Lua 5.5", 1, true))
    assert(not source55:find("Lua 5.4", 1, true))
    assert(source51 ~= source55, "different Lua ABIs produced identical launchers")
    local template = readFile("src/launcher/luai_launcher.c")
    assert(template:find("@LUA_VERSION_NUM@", 1, true))
    assert(template:find("@LUA_VERSION@", 1, true))
    local file_template_source = launcher.generateSource({
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
        lua_version = lua_info,
        template_path = "src/launcher/luai_launcher.c",
    })
    for source_name, source in pairs({
        embedded = generated,
        file = file_template_source,
    }) do
        assert(source:find(
            "const char *arg0 = argc > 0 && argv[0] != NULL ? argv[0] : \"\";",
            1,
            true
        ), source_name .. " launcher does not preserve a safe invocation arg[0]")
        assert(source:find("const char *executable_path = arg0;", 1, true),
            source_name .. " launcher does not separate arg[0] from its real path")
        assert(source:find('lua_setglobal(L, "__luai_executable_path");', 1, true),
            source_name .. " launcher cannot locate bundle metadata through symlinks")
    end

    local cgen = require("luainstaller.cgen")
    local payload_opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        dependencies = { scripts = {}, libraries = {} },
    }
    payload_opts.lua_version = { abi = "lua5.1" }
    local payload51 = cgen.generateBootstrap(payload_opts)
    payload_opts.lua_version = { abi = "lua5.5" }
    local payload55 = cgen.generateBootstrap(payload_opts)
    assert(payload51 ~= payload55, "Lua ABI did not change the generated payload")

    local manifest = require("luainstaller.manifest")
    local manifest51 = manifest.build({
        entry = "test/single_file/01_hello_luainstaller.lua",
        lua_version = { version = "Lua 5.1", major = 5, minor = 1, num = 501, abi = "lua5.1" },
    })
    local manifest55 = manifest.build({
        entry = "test/single_file/01_hello_luainstaller.lua",
        lua_version = { version = "Lua 5.5", major = 5, minor = 5, num = 505, abi = "lua5.5" },
    })
    assert(manifest51.ok and manifest55.ok)
    assert(manifest51.manifest.lua.major == 5 and manifest51.manifest.lua.minor == 1)
    assert(manifest55.manifest.lua.abi == "lua5.5")
    writeFile(c_path, generated)
    local compiled = commandSucceeds(table.concat({
        "cc -std=c11 -Wall -Wextra -Werror -pedantic -fsyntax-only",
        "-I" .. shellQuote(include_dir),
        "-I" .. shellQuote(selected_include),
        shellQuote(c_path),
        ">" .. shellQuote(log_path) .. " 2>&1",
    }, " "))
    assert(not compiled, "mismatched Lua headers passed the launcher guard")
    assert(readFile(log_path):find("generated for a different Lua ABI", 1, true))
    removeTree(root)
end)

test("onefile repeated builds are byte identical", function()
    local root = makeTempDir("onefile-reproducible")
    local out = root .. "/app"
    local opts = {
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    }
    local first = require("luainstaller").bundle(opts)
    assert(first.ok, first.error and first.error.message)
    local first_bytes = readFile(out)
    assert(os.remove(out))
    local second = require("luainstaller").bundle(opts)
    assert(second.ok, second.error and second.error.message)
    assert(readFile(out) == first_bytes, "onefile bytes differ")
    removeTree(root)
end)

test("onefile publication supports a near-NAME_MAX output basename", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-name-max")
    local out = root .. "/" .. string.rep("o", 240)
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    })
    assert(result.ok, result.error and result.error.message)
    assert(fileExists(out), "near-NAME_MAX onefile output is missing")
    runCommand(shellQuote(out) .. " name-max")
    removeTree(root)
end)

test("onefile cache repairs an equal-size FNV collision and mode", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-cache-exact")
    local cache = root .. "/cache"
    local out = root .. "/app"
    makeDirectory(cache)
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    })
    assert(result.ok, result.error and result.error.message)
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " first")
    local manifest_path = commandOutputTrimmed(
        "find " .. shellQuote(cache) .. " -path '*/.luai/manifest.lua' -type f -print -quit"
    )
    assert(manifest_path ~= "", "extracted manifest not found")
    local original = readFile(manifest_path)
    local collision = fnv1a32Collision(original)
    assert(#collision == #original and collision ~= original)
    assertEqual(
        require("luainstaller.hash").fnv1a32(collision),
        require("luainstaller.hash").fnv1a32(original),
        "FNV collision"
    )
    writeFile(manifest_path, collision)
    runCommand("chmod 700 " .. shellQuote(manifest_path))
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " second")
    assert(readFile(manifest_path) == original, "exact cache repair failed")
    runCommand("test ! -x " .. shellQuote(manifest_path))

    assert(os.remove(manifest_path))
    runCommand("mkfifo " .. shellQuote(manifest_path))
    local fifo_ok, _, fifo_code = harness.command_result(
        "timeout 5 env TMPDIR=" .. shellQuote(cache)
        .. " " .. shellQuote(out) .. " fifo >/dev/null 2>&1")
    assert(not fifo_ok, "extractor accepted a cache FIFO")
    assertEqual(fifo_code, 1, "cache FIFO rejection status")
    runCommand("test -p " .. shellQuote(manifest_path))
    assert(os.remove(manifest_path))
    runCommand("TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out) .. " repaired")
    assert(readFile(manifest_path) == original, "cache did not recover after unsafe entry removal")

    local luai_dir = manifest_path:match("^(.*)/manifest%.lua$")
    local victim = root .. "/symlink-victim"
    makeDirectory(victim)
    writeFile(victim .. "/manifest.lua", original)
    runCommand("chmod 700 " .. shellQuote(victim .. "/manifest.lua"))
    runCommand("rm -rf " .. shellQuote(luai_dir))
    runCommand("ln -s " .. shellQuote(victim) .. " " .. shellQuote(luai_dir))
    local linked_ok, _, linked_code = harness.command_result(
        "timeout 5 env TMPDIR=" .. shellQuote(cache) .. " " .. shellQuote(out)
            .. " linked-parent >/dev/null 2>&1"
    )
    assert(not linked_ok, "extractor accepted a linked cache parent")
    assertEqual(linked_code, 1, "linked cache parent rejection status")
    assert(readFile(victim .. "/manifest.lua") == original, "linked parent changed victim bytes")
    local executable_victim = harness.command_result(
        "test -x " .. shellQuote(victim .. "/manifest.lua"))
    assert(executable_victim, "linked parent changed victim mode before validation")
    removeTree(root)
end)

test("onefile rejects control bytes in the target filename", function()
    local root = makeTempDir("onefile-control-path")
    local out = root .. "/bad\11name"
    local result = require("luainstaller").bundle({
        entry = "test/single_file/01_hello_luainstaller.lua",
        mode = "onefile",
        out = out,
    })
    assert(not result.ok and result.error.type == "InvalidOptionsError")
    assert(not fileExists(out), "invalid onefile target was published")
    removeTree(root)
end)

test("onefile cleanup failure reports a committed output", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-committed-cleanup")
    local fake_bin = root .. "/bin"
    local out = root .. "/app"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/rm", [[#!/bin/sh
for value in "$@"; do
    case "$value" in
        *luainstaller-luai-output-*)
            printf '%s\n' 'injected output-stage cleanup failure' >&2
            exit 73
            ;;
    esac
done
exec "$LUAI_REAL_RM" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/rm"))
    local child = harness.loader_prelude() .. string.format([[
local result = require("luainstaller").bundle({
    entry = "test/single_file/01_hello_luainstaller.lua",
    mode = "onefile",
    out = %q,
})
assert(result.ok == false, "injected cleanup failure must be reported")
assert(result.error.type == "FilesystemError", result.error.type)
assert(result.error.committed == true, "published output must be marked committed")
assert(result.error.path == %q, "committed output path missing")
]], out, out)
    runCommand(table.concat({
        "LUAI_REAL_RM=" .. shellQuote(commandOutputTrimmed("command -v rm")),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    assert(fileExists(out), "committed output was lost after cleanup failure")
    runCommand(shellQuote(out) .. " committed")
    removeTree(root)
end)

test("onefile extractor is strict C11 and sanitizer clean", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("onefile-strict-extractor")
    local fake_bin = root .. "/bin"
    local captured = root .. "/extractor.c"
    local out = root .. "/app"
    makeDirectory(fake_bin)
    writeFile(fake_bin .. "/cc", [[#!/bin/sh
for value in "$@"; do
    case "$value" in
        */extractor.c)
            cp "$value" "$LUAI_CAPTURE_EXTRACTOR"
            cp "${value%/*}/payload.inc" "${LUAI_CAPTURE_EXTRACTOR%/*}/payload.inc"
            ;;
    esac
done
exec "$LUAI_REAL_CC" "$@"
]])
    runCommand("chmod +x " .. shellQuote(fake_bin .. "/cc"))
    local child = harness.loader_prelude() .. string.format([[
local bundler = require("luainstaller.bundler")
local onefile = require("luainstaller.onefile")
local original = bundler.bundleOnedir
bundler.bundleOnedir = function(opts)
    assert(require("luainstaller.process").output(
        "mkdir -p " .. require("luainstaller.process").shellQuote(opts.out .. "/utf8-雪")
            .. " " .. require("luainstaller.process").shellQuote(opts.out .. "/.luai")))
    local inner = assert(io.open(opts.out .. "/inner", "wb"))
    assert(inner:write("#!/bin/sh\nexit 0\n"))
    assert(inner:close())
    assert(require("luainstaller.process").output(
        "chmod 700 " .. require("luainstaller.process").shellQuote(opts.out .. "/inner")))
    local empty = assert(io.open(opts.out .. "/utf8-雪/empty.bin", "wb"))
    assert(empty:close())
    local long_name = string.rep("n", 240)
    local long_file = assert(io.open(opts.out .. "/" .. long_name, "wb"))
    assert(long_file:write("near-NAME_MAX payload component\n"))
    assert(long_file:close())
    local manifest = assert(io.open(opts.out .. "/.luai/manifest.lua", "wb"))
    assert(manifest:write("generated manifest bytes\n"))
    assert(manifest:close())
    return { ok = true, executable = opts.out .. "/inner", manifest = opts.manifest }
end
local result = onefile.bundleOnefile({
    entry = "test/single_file/01_hello_luainstaller.lua",
    out = %q,
    target_os = "linux",
})
bundler.bundleOnedir = original
assert(result.ok, result.error and result.error.message)
]], out)
    runCommand(table.concat({
        "LUAI_CAPTURE_EXTRACTOR=" .. shellQuote(captured),
        "LUAI_REAL_CC=" .. shellQuote(commandOutputTrimmed("command -v cc")),
        "PATH=" .. shellQuote(fake_bin .. ":/usr/bin:/bin"),
        luaCommand .. " -e " .. shellQuote(child),
    }, " "))
    assert(fileExists(captured), "extractor C source was not captured")
    local source = readFile(captured)
    local windows_run = assert(source:match(
        "(static int luai_append_quoted.-)#else\nstatic int luai_run_inner"
    ), "Windows onefile execution branch is missing")
    assert(source:find("#define _DARWIN_C_SOURCE 1", 1, true),
        "extractor does not expose Darwin no-follow flags under strict C11")
    assert(source:find('#define LUAI_INNER_EXE "\\', 1, true))
    assert(source:find("CreateProcessA(exe_path, cmd, NULL, NULL, FALSE", 1, true))
    assert(windows_run:find(
        "argc > 0 && argv[0] != NULL ? argv[0] : exe_path",
        1,
        true
    ), "Windows onefile does not safely construct argv[0]")
    assert(source:find("CreateJobObjectA", 1, true),
        "Windows onefile does not create a child-containment job")
    assert(source:find("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", 1, true),
        "Windows onefile job does not kill children when the outer handle closes")
    assert(source:find("AssignProcessToJobObject", 1, true),
        "Windows onefile does not assign its child to the containment job")
    assert(source:find("CREATE_SUSPENDED", 1, true),
        "Windows onefile child can run before job assignment")
    assert(not source:find("pid = fork();", 1, true),
        "POSIX onefile retains an unnecessary supervising process")
    assert(source:find("execv(exe_path, child_argv);", 1, true),
        "POSIX onefile does not replace itself with the inner launcher")
    assert(source:find(
        "child_argv[0] = argc > 0 && argv[0] != NULL ? argv[0] : exe_path;",
        1,
        true
    ), "POSIX onefile does not safely construct argv[0]")
    assert(not source:find("(char *)exe_path", 1, true),
        "POSIX onefile discards the executable-path const qualifier")
    assert(source:find("else if (!backslash) pos = slash", 1, true))
    assert(source:find("luai_pin_absolute_chain", 1, true),
        "Windows extractor does not pin the temporary-path ancestor chain")
    assert(source:find("luai_pin_relative_parents", 1, true),
        "Windows extractor does not pin payload parent directories")
    assert(source:find("FILE_FLAG_OPEN_REPARSE_POINT", 1, true),
        "Windows extractor follows reparse points while pinning cache objects")
    assert(source:find("CreateFileA(path, access, FILE_SHARE_READ,", 1, true),
        "Windows extractor permits write handles on pinned cache directories")
    assert(source:find("luai_close_pins", 1, true),
        "Windows extractor does not retain and close cache pins around execution")
    assert(source:find("luai_directory_entry_is_stable", 1, true),
        "POSIX extractor does not validate temporary-path directory stability")
    assert(source:find("S_IWGRP | S_IWOTH", 1, true)
            and source:find("S_ISVTX", 1, true),
        "POSIX extractor accepts a replaceable shared temporary-path ancestor")
    local ancestor_owner_check = source:find(
        "if (st.st_uid != 0 && st.st_uid != geteuid()) return 0;", 1, true)
    local ancestor_write_check = source:find(
        "shared_write = st.st_mode & (S_IWGRP | S_IWOTH);", 1, true)
    assert(ancestor_owner_check and ancestor_write_check
            and ancestor_owner_check < ancestor_write_check,
        "POSIX extractor trusts a non-writable ancestor owned by another user")
    local payload_include = readFile(root .. "/payload.inc")
    assert(payload_include:match("luai_file_%d+, 0, 0 }"), "empty file record missing")

    local hooked = source
    local function_body = [[
static void luai_test_swap_parent(const char *parent) {
    static int done = 0;
    const char *victim = getenv("LUAI_TEST_VICTIM");
    const char *slash;
    char payload[4096];
    char moved[4096];
    size_t length;
    if (done || !victim || !*victim) return;
    slash = strrchr(parent, '/');
    if (!slash) return;
    length = (size_t)(slash - parent);
    if (length == 0 || length >= sizeof(payload)) _exit(90);
    memcpy(payload, parent, length);
    payload[length] = '\0';
    if (snprintf(moved, sizeof(moved), "%s.old", payload) < 0) _exit(91);
    if (rename(payload, moved) != 0) _exit(92);
    if (symlink(victim, payload) != 0) _exit(93);
    done = 1;
}

]]
    local insertion = assert(hooked:find("#ifdef _WIN32\nstatic int luai_mkdir_one", 1, true))
    hooked = hooked:sub(1, insertion - 1) .. function_body .. hooked:sub(insertion)
    local fixed_hook_point = "    parent[parent_length] = '\\0';\n"
        .. "    write_result = luai_write_file_at"
    local hook_point, hook_end = hooked:find(fixed_hook_point, 1, true)
    if hook_point then
        local replacement = "    parent[parent_length] = '\\0';\n"
            .. "    luai_test_swap_parent(parent);\n"
            .. "    write_result = luai_write_file_at"
        hooked = hooked:sub(1, hook_point - 1) .. replacement .. hooked:sub(hook_end + 1)
    else
        local legacy_hook_point = "    if (luai_ensure_private_dir(parent) != 0) return -1;\n"
        hook_point, hook_end = hooked:find(legacy_hook_point, 1, true)
        assert(hook_point, "extractor parent validation hook point missing")
        local replacement = legacy_hook_point .. "    luai_test_swap_parent(parent);\n"
        hooked = hooked:sub(1, hook_point - 1) .. replacement .. hooked:sub(hook_end + 1)
    end
    local hooked_c = root .. "/extractor-parent-race.c"
    local hooked_exe = root .. "/extractor-parent-race"
    writeFile(hooked_c, hooked)
    runCommand("cc -std=c11 -Wall -Wextra -Werror -pedantic "
        .. shellQuote(hooked_c) .. " -o " .. shellQuote(hooked_exe))
    local race_cache = root .. "/race-cache"
    local victim = root .. "/victim"
    makeDirectory(race_cache)
    makeDirectory(victim .. "/.luai")
    runCommand("chmod 700 " .. shellQuote(race_cache) .. " "
        .. shellQuote(victim) .. " " .. shellQuote(victim .. "/.luai"))
    local victim_manifest = victim .. "/.luai/manifest.lua"
    writeFile(victim_manifest, "victim manifest must survive\n")
    runCommand("chmod 700 " .. shellQuote(victim_manifest))
    local hook_ok = commandSucceeds("TMPDIR=" .. shellQuote(race_cache)
        .. " LUAI_TEST_VICTIM=" .. shellQuote(victim)
        .. " " .. shellQuote(hooked_exe) .. " >/dev/null 2>&1")
    assert(not hook_ok,
        "swapped string path unexpectedly executed through the victim")
    local swapped_parent = commandOutputTrimmed(
        "find " .. shellQuote(race_cache) .. " -type l -print"
    )
    assert(swapped_parent ~= "" and not swapped_parent:find("\n", 1, true),
        "onefile parent replacement hook did not create exactly one symlink")
    assertEqual(commandOutputTrimmed("readlink " .. shellQuote(swapped_parent)), victim,
        "onefile parent replacement target")
    runCommand("test -d " .. shellQuote(swapped_parent .. ".old"))
    assertEqual(readFile(victim_manifest), "victim manifest must survive\n", "onefile parent race bytes")
    local victim_executable = commandSucceeds("test -x " .. shellQuote(victim_manifest))
    assert(victim_executable,
        "onefile parent race changed victim mode")

    local gcc_exe = root .. "/extractor-gcc"
    runCommand(table.concat({
        "cc -std=c11 -Wall -Wextra -Werror -pedantic",
        shellQuote(captured),
        "-o",
        shellQuote(gcc_exe),
    }, " "))
    local gcc_cache = root .. "/gcc-cache"
    makeDirectory(gcc_cache)
    runCommand("TMPDIR=" .. shellQuote(gcc_cache) .. " " .. shellQuote(gcc_exe))

    local shared_parent = root .. "/shared-parent"
    local shared_cache = shared_parent .. "/cache"
    makeDirectory(shared_cache)
    runCommand("chmod 0777 " .. shellQuote(shared_parent)
        .. " && chmod 0700 " .. shellQuote(shared_cache))
    local shared_ok = commandSucceeds("TMPDIR=" .. shellQuote(shared_cache)
        .. " " .. shellQuote(gcc_exe) .. " >/dev/null 2>&1")
    assert(not shared_ok,
        "onefile accepted a non-sticky writable TMPDIR ancestor")
    runCommand("chmod 1777 " .. shellQuote(shared_parent))
    runCommand("TMPDIR=" .. shellQuote(shared_cache) .. " " .. shellQuote(gcc_exe))

    local mingw = commandSucceeds("command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1")
    if mingw then
        local windows_one = root .. "/extractor-windows-1.exe"
        local windows_two = root .. "/extractor-windows-2.exe"
        local windows_command = table.concat({
            "x86_64-w64-mingw32-gcc -std=c11 -Wall -Wextra -Werror -pedantic",
            shellQuote(captured),
            "-o",
            "%s",
            "-static-libgcc -Wl,--no-insert-timestamp -ladvapi32",
        }, " ")
        runCommand(string.format(windows_command, shellQuote(windows_one)))
        runCommand(string.format(windows_command, shellQuote(windows_two)))
        assert(readFile(windows_one) == readFile(windows_two), "MinGW extractor is not reproducible")
    end

    local clang = commandSucceeds("command -v clang >/dev/null 2>&1")
    if clang then
        local clang_exe = root .. "/extractor-clang"
        runCommand(table.concat({
            "clang -std=c11 -Wall -Wextra -Werror -pedantic",
            "-fsanitize=address,undefined -fno-omit-frame-pointer",
            shellQuote(captured),
            "-o",
            shellQuote(clang_exe),
        }, " "))
        local clang_cache = root .. "/clang-cache"
        makeDirectory(clang_cache)
        runCommand("ASAN_OPTIONS=detect_leaks=1 TMPDIR=" .. shellQuote(clang_cache)
            .. " " .. shellQuote(clang_exe))
    end
    removeTree(root)
end)

test("logger retains concurrent writers", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-concurrency")
    local home = root .. "/home"
    makeDirectory(home)

    local workers = {
        "#!/bin/sh",
        "status=0",
        "pids=",
    }
    for index = 1, 60 do
        local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
assert(logger.logInfo("edge", "parallel", %q) == true)
]], "worker-" .. index)
        workers[#workers + 1] = table.concat({
            "HOME=" .. shellQuote(home),
            luaCommand .. " -e " .. shellQuote(child),
            "&",
        }, " ")
        workers[#workers + 1] = 'pids="$pids $!"'
    end
    workers[#workers + 1] = 'for pid in $pids; do wait "$pid" || status=1; done'
    workers[#workers + 1] = 'exit "$status"'

    local worker_script = root .. "/workers.sh"
    writeFile(worker_script, table.concat(workers, "\n") .. "\n")
    runCommand("chmod 700 " .. shellQuote(worker_script))
    runCommand(shellQuote(worker_script))

    local verify = harness.loader_prelude() .. [[
local logs = require("luainstaller.logger").getLogs({ descending = false })
assert(#logs == 60, "expected 60 retained logs, got " .. tostring(#logs))
local seen = {}
for _, entry in ipairs(logs) do
    assert(entry.source == "edge" and entry.action == "parallel")
    assert(not seen[entry.message], "duplicate worker log: " .. tostring(entry.message))
    seen[entry.message] = true
end
for index = 1, 60 do
    assert(seen["worker-" .. index], "missing worker log " .. index)
end
print("logger concurrency ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(verify))
    assert(output:find("logger concurrency ok", 1, true))
    removeTree(root)
end)

test("logger preserves the previous file on a failed transaction", function()
    local root = makeTempDir("logger-write-failure")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local path = %q
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "preserve", "before") == true)
local input = assert(io.open(path, "rb"))
local original = assert(input:read("*a"))
assert(input:close())
local backup_input = assert(io.open(path .. ".bak", "rb"))
local original_backup = assert(backup_input:read("*a"))
assert(backup_input:close())
assert(type(assert(require("luainstaller.compat").loadText(
    original, "@logs.lua", {}
))()) == "table")

local saved_open = io.open
io.open = function(candidate, mode)
    local is_log_write = mode == "wb"
        and (candidate == path or candidate:find("logs.lua.tmp.", 1, true))
    if not is_log_write then
        return saved_open(candidate, mode)
    end
    local real = assert(saved_open(candidate, mode))
    return {
        write = function()
            return nil, "simulated disk full"
        end,
        flush = function()
            return real:flush()
        end,
        close = function()
            return real:close()
        end,
    }
end
assert(logger.clearLogs() == false, "failed transaction must be reported")
io.open = saved_open

local after_handle = assert(io.open(path, "rb"))
local after = assert(after_handle:read("*a"))
assert(after_handle:close())
assert(after == original, "failed transaction changed the primary log")
local backup_after_handle = assert(io.open(path .. ".bak", "rb"))
local backup_after = assert(backup_after_handle:read("*a"))
assert(backup_after_handle:close())
assert(backup_after == original_backup, "failed transaction changed the backup log")
local logs = logger.getLogs({ descending = false })
assert(#logs == 1 and logs[1].message == "before")
print("logger failure preservation ok")
]], home .. "/.luainstaller/logs.lua")
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger failure preservation ok", 1, true))
    removeTree(root)
end)

test("logger clear cannot resurrect entries from its backup", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-clear-backup")
    local script = harness.loader_prelude() .. [[
local logger = require("luainstaller.logger")
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "clear", "sensitive") == true)
assert(logger.clearLogs() == true)
local path = os.getenv("HOME") .. "/.luainstaller/logs.lua"
assert(os.remove(path))
local logs = logger.getLogs()
assert(#logs == 0, "cleared backup resurrected " .. tostring(#logs) .. " entries")
print("logger clear backup ok")
]]
    local output = runCommand("HOME=" .. shellQuote(root) .. " "
        .. luaCommand .. " -e " .. shellQuote(script))
    assert(output:find("logger clear backup ok", 1, true))
    removeTree(root)
end)

test("logger times out without releasing another owner lock", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-owned-lock")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local directory = %q
local lock = directory .. "/logs.lua.lock"
assert(require("luainstaller.process").output(
    "mkdir -p " .. require("luainstaller.process").shellQuote(lock)))
local content = "created=" .. tostring(os.time()) .. "\ntoken=active-owner\n"
for _, name in ipairs({ "owner", "owner.active-owner" }) do
    local handle = assert(io.open(lock .. "/" .. name, "wb"))
    assert(handle:write(content))
    assert(handle:close())
end
local started = os.time()
assert(logger.clearLogs() == false, "active lock must not be stolen")
assert(os.time() - started >= 4, "lock acquisition returned before its timeout")
for _, name in ipairs({ "owner", "owner.active-owner" }) do
    local handle = assert(io.open(lock .. "/" .. name, "rb"))
    assert(handle:read("*a") == content, "another owner's lock was changed")
    assert(handle:close())
    assert(os.remove(lock .. "/" .. name))
end
assert(os.remove(lock))
print("logger owned-lock timeout ok")
]], home .. "/.luainstaller")
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger owned-lock timeout ok", 1, true))
    removeTree(root)
end)

test("logger release preserves a replacement owner record", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-release-replacement")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local fs = require("luainstaller.fs")
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
local replacement
local replacement_token
local original_rename = os.rename
local injected = false

rawset(os, "rename", function(from, to)
    if not injected and from == lock and tostring(to):find(".release.", 1, true) then
        injected = true
        local owner_name = process.firstLine("cd " .. process.shellQuote(lock)
            .. " && for item in owner.*; do test -f \"$item\" && printf '%s\\n' \"$item\"; done")
        replacement_token = assert(owner_name and owner_name:match("^owner%.([%w_.-]+)$"),
            "active logger token was not found")
        replacement = "created=1\ntoken=" .. replacement_token .. "\n"
        assert(original_rename(lock, lock .. ".original"))
        assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
        assert(fs.writeFile(lock .. "/owner", replacement))
        assert(fs.writeFile(lock .. "/owner." .. replacement_token, replacement))
        assert(fs.writeFile(lock .. "/SENTINEL", "replacement lock must survive\n"))
    end
    return original_rename(from, to)
end)

local cleared = logger.clearLogs()
rawset(os, "rename", original_rename)
assert(cleared == false, "release of a replaced lock must fail closed")
assert(injected, "logger replacement hook did not run")
assert(fs.readFile(lock .. "/owner") == replacement, "replacement generic owner was changed")
assert(fs.readFile(lock .. "/owner." .. replacement_token) == replacement,
    "replacement token owner was changed")
assert(fs.readFile(lock .. "/SENTINEL") == "replacement lock must survive\n",
    "replacement sentinel was changed")
print("logger replacement release ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger replacement release ok", 1, true))
    removeTree(root)
end)

test("logger release leaves a newly acquired empty lock untouched", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-new-owner-window")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local process = require("luainstaller.process")
local logger = require("luainstaller.logger")
local compat = require("luainstaller.compat")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
local original_remove = os.remove
local original_rename = os.rename
local injected = false

rawset(os, "remove", function(candidate)
    if not injected and type(candidate) == "string"
        and candidate:find("logs%.lua%.lock") and candidate:find("/owner%.") then
        local values = compat.pack(original_remove(candidate))
        if values[1] then
            injected = true
            local cleanup_lock = candidate:match("^(.*)/owner%.")
            local active_lock = cleanup_lock:gsub("%.release%.[%w_.-]+$", "")
            if cleanup_lock == active_lock then
                assert(original_rename(cleanup_lock, cleanup_lock .. ".previous-owner"))
            end
            assert(process.output("mkdir -m 700 " .. process.shellQuote(active_lock)))
        end
        return compat.unpack(values, 1, values.n)
    end
    return original_remove(candidate)
end)

assert(logger.clearLogs() == true)
rawset(os, "remove", original_remove)
assert(injected, "post-sentinel logger acquisition hook did not run")
assert(process.output("test -d " .. process.shellQuote(lock)))
print("logger new owner window ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger new owner window ok", 1, true))
    removeTree(root)
end)

test("logger stale recovery preserves a lock replaced after observation", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-stale-observation-replacement")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local fs = require("luainstaller.fs")
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
local replacement = "created=" .. tostring(os.time()) .. "\ntoken=new-active\n"
assert(logger.clearLogs() == true)
assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
assert(fs.writeFile(lock .. "/owner",
    "created=" .. tostring(os.time() - 1000) .. "\ntoken=observed-stale\n"))

local original_rename = os.rename
local injected = false
rawset(os, "rename", function(from, to)
    if not injected and from == lock and tostring(to):find(".stale.", 1, true) then
        injected = true
        assert(original_rename(lock, lock .. ".observed-stale"))
        assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
        assert(fs.writeFile(lock .. "/owner.new-active", replacement))
    end
    return original_rename(from, to)
end)

local cleared = logger.clearLogs()
rawset(os, "rename", original_rename)
assert(injected, "stale-lock replacement hook did not run")
assert(cleared == false, "logger stole a newly active replacement lock")
assert(fs.readFile(lock .. "/owner.new-active") == replacement,
    "newly active replacement lock was changed")
print("logger stale observation replacement ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger stale observation replacement ok", 1, true))
    removeTree(root)
end)

test("logger never reclaims a recent dead-owner lock", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-recent-dead-owner")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local fs = require("luainstaller.fs")
local lock_owner = require("luainstaller.lock_owner")
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
assert(logger.clearLogs() == true)
assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
local owner = assert(lock_owner.encode({
    token = "recent-dead-owner-token",
    pid = "4194303",
    created = os.time(),
}))
assert(fs.writeFile(lock .. "/owner.recent-dead-owner-token", owner))
assert(logger.clearLogs() == false, "a recent dead-owner lock was reclaimed")
assert(fs.readFile(lock .. "/owner.recent-dead-owner-token") == owner,
    "the recent dead-owner lock was changed")
print("logger recent dead owner preserved")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger recent dead owner preserved", 1, true))
    removeTree(root)
end)

test("logger revalidates a stale lock after the liveness probe", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-liveness-revalidation")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local fs = require("luainstaller.fs")
local lock_owner = require("luainstaller.lock_owner")
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
assert(logger.clearLogs() == true)
assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
local stale = assert(lock_owner.encode({
    token = "observed-dead-owner-token",
    pid = "4194303",
    created = os.time() - 1000,
}))
assert(fs.writeFile(lock .. "/owner.observed-dead-owner-token", stale))

local replacement = "created=" .. tostring(os.time()) .. "\ntoken=new-live-owner-token\n"
local original_alive = lock_owner.isAlive
local original_rename = os.rename
local injected = false
local replacement_moved = false
lock_owner.isAlive = function(pid)
    if not injected and tostring(pid) == "4194303" then
        injected = true
        assert(original_rename(lock, lock .. ".observed-stale"))
        assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
        assert(fs.writeFile(lock .. "/owner.new-live-owner-token", replacement))
        return false
    end
    return original_alive(pid)
end
os.rename = function(from, to)
    if injected and from == lock and tostring(to):find(".stale.", 1, true) then
        replacement_moved = true
    end
    return original_rename(from, to)
end

local cleared = logger.clearLogs()
lock_owner.isAlive = original_alive
os.rename = original_rename
assert(injected, "liveness replacement hook did not run")
assert(cleared == false, "logger acquired a replacement lock")
assert(not replacement_moved, "logger moved a lock replaced during the liveness probe")
assert(fs.readFile(lock .. "/owner.new-live-owner-token") == replacement,
    "the replacement lock was changed")
print("logger liveness replacement preserved")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger liveness replacement preserved", 1, true))
    removeTree(root)
end)

test("logger recovers a backup and a stale owned lock", function()
    if package.config:sub(1, 1) ~= "/" then
        return
    end
    local root = makeTempDir("logger-recovery")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. string.format([[
local logger = require("luainstaller.logger")
local directory = %q
local path = directory .. "/logs.lua"
local backup = path .. ".bak"
local lock = path .. ".lock"
assert(logger.clearLogs() == true)
assert(logger.logInfo("edge", "recover", "before") == true)
assert(os.rename(path, backup))
assert(require("luainstaller.process").output(
    "mkdir " .. require("luainstaller.process").shellQuote(lock)))
local owner = assert(io.open(lock .. "/owner", "wb"))
assert(owner:write("created=" .. tostring(os.time() - 1000) .. "\ntoken=abandoned\n"))
assert(owner:close())
assert(logger.logInfo("edge", "recover", "after") == true)
local logs = logger.getLogs({ descending = false })
assert(#logs == 2, "backup recovery lost entries: " .. tostring(#logs))
assert(logs[1].message == "before" and logs[2].message == "after")
local lock_probe = io.open(lock .. "/owner", "rb")
assert(lock_probe == nil, "stale lock remains")
local primary = assert(io.open(path, "rb"))
assert(primary:read(1) ~= nil, "primary log was not restored")
assert(primary:close())
print("logger stale recovery ok")
]], home .. "/.luainstaller")
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger stale recovery ok", 1, true))
    removeTree(root)
end)

test("logger recovers an empty stale lock left before owner publication", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-empty-stale-lock")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
assert(logger.clearLogs() == true)
assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
assert(process.output("touch -t 200001010000 " .. process.shellQuote(lock)))
assert(logger.clearLogs() == true, "empty abandoned lock was not recovered")
assert(process.output("test ! -e " .. process.shellQuote(lock)))
print("logger empty stale lock recovery ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger empty stale lock recovery ok", 1, true))
    removeTree(root)
end)

test("logger stale recovery preserves an empty lock replaced after observation", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = makeTempDir("logger-empty-stale-replacement")
    local home = root .. "/home"
    makeDirectory(home)
    local child = harness.loader_prelude() .. [[
local logger = require("luainstaller.logger")
local process = require("luainstaller.process")
local lock = os.getenv("HOME") .. "/.luainstaller/logs.lua.lock"
assert(logger.clearLogs() == true)
assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
assert(process.output("touch -t 200001010000 " .. process.shellQuote(lock)))

local original_rename = os.rename
local injected = false
local replacement_identity
rawset(os, "rename", function(from, to)
    if not injected and from == lock and tostring(to):find(".stale.", 1, true) then
        injected = true
        assert(original_rename(lock, lock .. ".observed-stale"))
        assert(process.output("mkdir -m 700 " .. process.shellQuote(lock)))
        replacement_identity = assert(process.firstLine("stat -c '%d:%i' "
            .. process.shellQuote(lock)))
    end
    return original_rename(from, to)
end)

local cleared = logger.clearLogs()
rawset(os, "rename", original_rename)
assert(injected, "empty stale-lock replacement hook did not run")
assert(cleared == false, "logger treated a newly created empty lock as stale")
assert(process.firstLine("stat -c '%d:%i' " .. process.shellQuote(lock))
    == replacement_identity, "new empty lock identity was not preserved")
print("logger empty stale replacement ok")
]]
    local output = runCommand("HOME=" .. shellQuote(home) .. " "
        .. luaCommand .. " -e " .. shellQuote(child))
    assert(output:find("logger empty stale replacement ok", 1, true))
    removeTree(root)
end)

test("remote scripts are pinned and non-destructive", function()
    local posix_matrix = readFile("tools/test-lua-versions.sh")
    local windows_matrix = readFile("tools/test-lua-versions.ps1")
    local linux_runner = readFile("tools/remote-test-linux.sh")
    local macos_runner = readFile("tools/remote-test-macos.sh")
    local windows_runner = readFile("tools/remote-test-windows.sh")
    local interruption_test = readFile("test/build_interruption.lua")
    assert(not interruption_test:find(
        'signal_name .. " -- \\"-$build\\""',
        1,
        true
    ), "build interruption test uses a kill separator rejected by dash")
    assert(interruption_test:find(
        'signal_name .. " \\"-$build\\""',
        1,
        true
    ), "build interruption test does not signal the build process group")
    for _, clean_test in ipairs({
        "test/native_bundle.lua",
        "test/native_onefile.lua",
        "test/distribution_licenses.lua",
        "test/reproducible_artifacts.lua",
    }) do
        local source = readFile(clean_test)
        assert(source:find('path.join(root, "empty-path")', 1, true),
            clean_test .. " does not create a private empty PATH")
        assert(not source:find("/usr/bin:/bin", 1, true),
            clean_test .. " can still discover a host Lua interpreter")
        assert(not source:find("C:\\Windows\\System32;C:\\Windows", 1, true),
            clean_test .. " can still discover a Windows Lua interpreter")
    end
    assert(not readFile("test/smoke_all.lua"):find(
        "/tmp/luainstaller-single.",
        1,
        true
    ), "smoke suite writes through predictable shared temporary files")
    for _, version in ipairs({ "5.1.5", "5.2.4", "5.3.6", "5.4.8", "5.5.0" }) do
        assert(posix_matrix:find(version, 1, true), "POSIX matrix omits Lua " .. version)
        assert(windows_matrix:find(version, 1, true), "Windows matrix omits Lua " .. version)
    end
    assert(posix_matrix:find("LUAROCKS_VERSION=3.13.0", 1, true))
    assert(posix_matrix:find("MYLIBS='-Wl,-E -ldl'", 1, true),
        "POSIX matrix does not disable Lua's optional readline dependency")
    assert(posix_matrix:find('make -C "$source_dir/src" all', 1, true),
        "POSIX matrix still delegates to Lua's interactive Linux make target")
    assert(posix_matrix:find("-DLUA_USE_POSIX -DLUA_USE_DLOPEN", 1, true),
        "POSIX matrix does not enable the non-interactive POSIX/dlopen feature set")
    assert(not posix_matrix:find("-DLUA_USE_LINUX", 1, true),
        "POSIX matrix enables Lua 5.1's readline-coupled Linux macro")
    assert(not posix_matrix:find('make -C "$source_dir" linux', 1, true),
        "POSIX matrix invokes Lua's readline-enabled Linux make target")
    assert(not posix_matrix:lower():find("readline", 1, true),
        "POSIX matrix requires the optional readline development headers")
    assert(posix_matrix:find('cc -shared -Wl,-soname,"liblua.so.$abi"', 1, true),
        "POSIX matrix does not build an ABI-versioned shared liblua")
    assert(posix_matrix:find('readelf -d "$runtime"', 1, true),
        "POSIX matrix does not verify the shared liblua SONAME")
    assert(posix_matrix:find('ln -s "liblua.so.$abi"', 1, true),
        "POSIX matrix does not use relative shared-liblua links")
    assert(posix_matrix:find('lib/pkgconfig/lua.pc', 1, true),
        "POSIX matrix does not publish selected-ABI pkg-config metadata")
    assert(posix_matrix:find('export PKG_CONFIG_PATH=', 1, true),
        "POSIX matrix native fixtures can use host Lua headers")
    local universal_commands = assert(posix_matrix:match(
        "for command in ([^\n]+); do"
    ), "POSIX matrix has no universal tool prerequisite list")
    assert(not universal_commands:find("pkg-config", 1, true),
        "POSIX matrix requires pkg-config on a clean macOS host")
    assert(posix_matrix:find("lua_pc_version()", 1, true),
        "POSIX matrix cannot validate lua.pc without pkg-config")
    assert(posix_matrix:find(
        'command -v pkg-config >/dev/null 2>&1 || { echo "missing command: pkg-config"',
        1,
        true
    ), "Linux matrix does not require pkg-config for its full edge gate")
    assert(not readFile("test/production_edges.lua"):find(
        "$(pkg-config" .. " --cflags lua)",
        1,
        true
    ), "production edge suite cannot compile on a pkg-config-free macOS host")
    assert(posix_matrix:find('"$lua" test/lua_abi.lua', 1, true),
        "POSIX matrix omits the ABI capability contract")
    assert(windows_matrix:find("'lua_abi.lua'", 1, true),
        "Windows matrix omits the ABI capability contract")
    assert(windows_matrix:find("'luac.exe'", 1, true),
        "Windows matrix does not build the selected release's bytecode checker")
    local _, exact_luac_checks = windows_matrix:gsub(
        "Test%-ExactLuaRelease %$luac %$version",
        ""
    )
    assert(exact_luac_checks >= 2,
        "Windows matrix does not validate the built luac patch release")
    assert(windows_matrix:find("LUAI_TEST_LUAC", 1, true),
        "Windows matrix can syntax-check with a host luac")
    assert(windows_matrix:find("Invoke-Native $luac @('-p'", 1, true),
        "Windows matrix does not parse sources and tests with the selected luac")
    for _, suite in ipairs({
        "test/distribution_licenses.lua",
        "test/reproducible_artifacts.lua",
        "test/production_edges.lua",
        "test/smoke_all.lua",
    }) do
        assert(posix_matrix:find(suite, 1, true),
            "POSIX matrix omits required suite " .. suite)
    end
    for _, suite in ipairs({
        "'release_docs_contract.lua'",
        "'distribution_licenses.lua'",
        "'reproducible_artifacts.lua'",
    }) do
        assert(windows_matrix:find(suite, 1, true),
            "Windows matrix omits required suite " .. suite)
    end
    assert(not posix_matrix:find("RUN_FULL_SUITE", 1, true),
        "POSIX release matrix makes required coverage optional")
    assert(posix_matrix:find("VERSION_FILTER", 1, true),
        "POSIX matrix cannot safely target one pinned release for diagnosis")
    assert(posix_matrix:find("LUAI_LUA_RELEASE", 1, true),
        "POSIX matrix does not publish the exact Lua patch release to tests")
    assert(posix_matrix:find("find src test tools -type f -name '*.lua'", 1, true),
        "POSIX matrix does not parse every shipped Lua source with exact luac")
    assert(windows_matrix:find("LUAI_LUA_RELEASE", 1, true),
        "Windows matrix does not publish the exact Lua patch release to tests")
    assert(windows_matrix:find("@('src','test','tools')", 1, true),
        "Windows matrix does not parse every shipped Lua source with exact luac")
    assert(posix_matrix:find(
        "245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37",
        1,
        true
    ))
    assert(windows_matrix:find("$LuaRocksVersion = '3.13.0'", 1, true))
    assert(windows_matrix:find(
        "0897ADE5D459D55CD1962A948153745A6749FEB345403C68AAA9207388557AB9",
        1,
        true
    ))
    for _, pin in ipairs({
        "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333",
        "b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b",
        "fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60",
        "4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae",
        "57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d",
    }) do
        assert(posix_matrix:find(pin, 1, true), "POSIX matrix lacks official Lua SHA-256")
        assert(windows_matrix:lower():find(pin, 1, true),
            "Windows matrix lacks official Lua SHA-256")
    end
    assert(posix_matrix:find("require_safe_tmp_path()", 1, true))
    assert(posix_matrix:find("require_owned_private_root()", 1, true),
        "POSIX matrix does not verify temporary-root ownership")
    assert(posix_matrix:find("stage_source()", 1, true))
    assert(posix_matrix:find("sha256_file()", 1, true),
        "POSIX matrix lacks a portable SHA-256 adapter")
    assert(posix_matrix:find("shasum -a 256", 1, true),
        "POSIX matrix cannot verify sources on a clean macOS host")
    assert(not posix_matrix:find("sha256sum -c", 1, true),
        "POSIX matrix retains a GNU-only hash verification path")
    assert(posix_matrix:find("CACHE_SCHEMA=", 1, true),
        "POSIX matrix caches have no exact schema marker")
    assert(posix_matrix:find("cache_marker_matches", 1, true),
        "POSIX matrix does not validate exact cache provenance")
    assert(posix_matrix:find("deps_install_order_hash", 1, true),
        "POSIX native dependency cache does not bind installation order")
    assert(posix_matrix:find("build_native_dependencies()", 1, true),
        "POSIX matrix does not provision sample dependencies per Lua ABI")
    assert(posix_matrix:find("--deps-mode=none", 1, true),
        "POSIX matrix permits LuaRocks to resolve unpinned transitive dependencies")
    for _, dependency in ipairs({
        "lua-cjson-2.1.0.10-1.src.rock",
        "luafilesystem-1.9.0-1.src.rock",
        "luasocket-3.1.0-1.src.rock",
        "mimetypes-1.1.0-2.src.rock",
        "lzlib-0.4.1.53-4.src.rock",
        "pegasus-1.1.0-0.src.rock",
        "lsqlite3_v096.zip",
        "sqlite-amalgamation-3530200.zip",
    }) do
        assert(posix_matrix:find(dependency, 1, true),
            "POSIX matrix omits pinned sample source " .. dependency)
    end
    for _, digest in ipairs({
        "02dea368d07753647c75bd9e6660dd4d06ff7d09956d90d5afc4c3f5b78ed187",
        "3de68d619f6ad95a27f4728814375447d921305194b7050dee6199057c31282f",
        "f4a207f50a3f99ad65def8e29c54ac9aac668b216476f7fae3fae92413398ed2",
        "2cf77e0b6575caa6aecb43c9a06f705b1e7d92c19c5da6bb2f07a10feeee9e2f",
        "860c893fc53d0a7830a54fa64f22a2b89260ca39c9a7dcb0890f6d3029f00ca5",
        "0f91f10e354183db06c0c2dfa878b97a0f75dc2777f4c971fbd44f848795f746",
        "ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82",
        "8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32",
    }) do
        assert(posix_matrix:find(digest, 1, true),
            "POSIX matrix omits sample source SHA-256 " .. digest)
    end
    assert(posix_matrix:find('export LUA_PATH="$DEPS_LUA_PATH"', 1, true),
        "POSIX matrix does not isolate sample Lua modules to its ABI rock tree")
    assert(posix_matrix:find('export LUA_CPATH="$DEPS_LUA_CPATH"', 1, true),
        "POSIX matrix does not isolate sample native modules to its ABI rock tree")
    assert(posix_matrix:find('require("lsqlite3")', 1, true),
        "POSIX matrix does not load-test its locally compiled SQLite module")
    assert(posix_matrix:find(
        'unzip -q "$SOURCE_CACHE/$SQLITE_ZIP" -d "$deps_build_dir/sqlite-src"',
        1,
        true
    ), "POSIX matrix does not isolate the pinned SQLite amalgamation")
    assert(posix_matrix:find(
        'LSQLITE3_SOURCE_MEMBER=lsqlite3_v096/lsqlite3.c',
        1,
        true
    ) and posix_matrix:find(
        'deps_lsqlite_file=$deps_build_dir/lsqlite3-src/$LSQLITE3_SOURCE_MEMBER',
        1,
        true
    ), "POSIX matrix does not require the pinned lsqlite3 source member")
    assert(posix_matrix:find(
        'SQLITE_SOURCE_MEMBER=sqlite-amalgamation-3530200/sqlite3.c',
        1,
        true
    ) and posix_matrix:find(
        'deps_sqlite_file=$deps_build_dir/sqlite-src/$SQLITE_SOURCE_MEMBER',
        1,
        true
    ), "POSIX matrix does not require the pinned SQLite source member")
    assert(posix_matrix:find('[ -L "$deps_sqlite_file" ]', 1, true),
        "POSIX matrix accepts a symlink in place of pinned SQLite source")
    assert(posix_matrix:find("SQLite amalgamation source:", 1, true),
        "POSIX matrix does not report the exact SQLite source it compiles")
    local provenance_position = assert(posix_matrix:find(
        '"SQLite amalgamation source: archive=$SQLITE_ZIP ' ..
            'sha256=$SQLITE_SHA256 member=$SQLITE_SOURCE_MEMBER"',
        1,
        true
    ), "POSIX matrix does not record pinned SQLite provenance")
    local cache_check_position = assert(posix_matrix:find(
        'if cache_marker_matches "$deps_marker"',
        1,
        true
    ), "POSIX matrix has no native-dependency cache check")
    assert(provenance_position < cache_check_position,
        "POSIX matrix omits SQLite provenance when its dependency cache hits")
    assert(posix_matrix:find("native dependency cache result: hit", 1, true),
        "POSIX matrix does not make native-dependency cache reuse auditable")
    assert(posix_matrix:find("native dependency cache result: rebuild", 1, true),
        "POSIX matrix does not make native-dependency rebuilds auditable")
    assert(posix_matrix:find(
        "recipe=pinned-src-rocks-lsqlite-v3-exact-sqlite-paths",
        1,
        true
    ), "POSIX matrix does not invalidate the ambiguous SQLite cache recipe")
    assert(posix_matrix:find("LUAI_REQUIRE_FULL_EDGE_COVERAGE=1", 1, true)
            and posix_matrix:find(
                '"$edge_lua" test/production_edges.lua',
                1,
                true
            ),
        "Linux matrix does not make full edge prerequisites mandatory")
    assert(posix_matrix:find(
        'LUAI_MATRIX_EDGE_COVERAGE_MODE=${LUAI_MATRIX_EDGE_COVERAGE_MODE:-full}',
        1,
        true
    ), "POSIX matrix does not default its local edge gate to strict coverage")
    assert(posix_matrix:find("strict edge prerequisites unavailable:", 1, true),
        "POSIX matrix does not report capability-aware edge coverage")
    local _, remote_available_gates = linux_runner:gsub(
        "LUAI_MATRIX_EDGE_COVERAGE_MODE=available",
        ""
    )
    assertEqual(remote_available_gates, 3,
        "Linux physical runner does not select capability-aware coverage per host")
    assert(windows_matrix:find("Assert-SafeRoot", 1, true))
    assert(windows_matrix:find("Stage-Source", 1, true))
    assert(windows_matrix:find("Get-FileHash", 1, true))
    assert(windows_matrix:find("$CacheSchema =", 1, true),
        "Windows matrix caches have no exact schema marker")
    assert(windows_matrix:find("Test-CacheMarker", 1, true),
        "Windows matrix does not validate exact cache provenance")
    assert(linux_runner:find(
        "git -c tar.umask=0022 archive --format=tar HEAD",
        1,
        true
    ), "Linux tracked archive does not normalize modes to the git index")
    assert(macos_runner:find(
        "git -c tar.umask=0022 archive --format=tar HEAD",
        1,
        true
    ), "macOS tracked archive does not normalize modes to the git index")
    assert(not linux_runner:find("git archive --format=tar HEAD", 1, true))
    assert(not macos_runner:find("git archive --format=tar HEAD", 1, true))
    local _, linux_exact_extracts = linux_runner:gsub("tar %-xpf %-", "")
    assertEqual(linux_exact_extracts, 2,
        "Linux remote transfers do not preserve tracked file modes")
    assert(macos_runner:find("tar -xpf -", 1, true),
        "macOS remote transfer does not preserve tracked file modes")
    assert(not linux_runner:find("tar -xf -", 1, true),
        "Linux remote transfer is still filtered through the remote umask")
    assert(not macos_runner:find("tar -xf -", 1, true),
        "macOS remote transfer is still filtered through the remote umask")
    assert(not macos_runner:find("pkg-config --modversion", 1, true),
        "macOS runner requires a non-system pkg-config installation")
    assert(macos_runner:find("/^Version:/", 1, true),
        "macOS runner does not validate the selected lua.pc directly")
    assert(macos_runner:find("find src test tools -type f -name '*.lua'", 1, true),
        "macOS runner omits shipped Lua sources from its exact-luac pass")
    assert(linux_runner:find("find src test tools -type f -name '*.lua'", 1, true),
        "Linux runner omits shipped Lua sources from its exact-luac pass")
    assert(not linux_runner:find("git ls-files", 1, true))
    assert(not macos_runner:find("git ls-files", 1, true))
    for runner_name, runner in pairs({
        ["Linux remote runner"] = linux_runner,
        ["macOS remote runner"] = macos_runner,
    }) do
        assert(runner:find("MATRIX_WORK_ROOT=", 1, true),
            runner_name .. " does not name its shared ABI-matrix root")
        for _, selected_output in ipairs({
            "lua-5.4.8",
            "luarocks-5.4.8",
            "native-deps-5.4.8",
        }) do
            assert(runner:find(selected_output, 1, true),
                runner_name .. " does not reuse matrix output " .. selected_output)
        end
        assert(runner:find("TEST_ROOT=", 1, true),
            runner_name .. " does not isolate supplemental artifacts per run")
        assert(runner:find("renice 15 -p $$", 1, true),
            runner_name .. " does not lower physical-host CPU priority")
        assert(not runner:find("command -v lua", 1, true),
            runner_name .. " can silently test a host Lua ABI")
        assert(not runner:find("command -v luac", 1, true),
            runner_name .. " can silently syntax-check with a host Lua ABI")
        assert(not runner:find(" install --force lua-", 1, true),
            runner_name .. " resolves sample dependencies outside the pinned matrix")
        assert(runner:find("EMPTY_PATH=", 1, true),
            runner_name .. " does not create a private empty PATH")
        assert(runner:find('env -i PATH="$EMPTY_PATH"', 1, true)
                or runner:find('env -i PATH="\\$EMPTY_PATH"', 1, true),
            runner_name .. " does not execute artifacts with the empty PATH")
        assert(not runner:find("env -i PATH=/usr/bin:/bin", 1, true),
            runner_name .. " clean target can still discover a host Lua")
    end
    assert(linux_runner:find("ionice -c 3 -p $$", 1, true),
        "Linux runner does not lower physical-host I/O priority")
    for name, content in pairs({
        posix = posix_matrix,
        powershell = windows_matrix,
        windows_launcher = windows_runner,
    }) do
        local lowered = content:lower()
        assert(not lowered:find("wine", 1, true), name .. " requires Wine")
        if name ~= "posix" then
            assert(not lowered:find("mingw", 1, true), name .. " requires MinGW")
        end
        assert(not lowered:find("virtual machine", 1, true), name .. " requires a VM")
        assert(not lowered:find("windows vm", 1, true), name .. " requires a VM")
    end
    assert(not windows_runner:lower():find("ssh", 1, true),
        "native Windows runner still requires SSH")
    assert(not linux_runner:find("lua test/", 1, true),
        "Linux runner invokes tests through a bare lua command")
    assert(not macos_runner:find("lua test/", 1, true),
        "macOS runner invokes tests through a bare lua command")
end)

local filter = os.getenv("EDGE_FILTER")
local ran = 0

for _, item in ipairs(tests) do
    if not filter or item.name:find(filter, 1, true) then
        item.fn()
        ran = ran + 1
        io.write("ok - ", item.name, "\n")
    end
end

assert(ran > 0, "EDGE_FILTER selected no tests")
io.write(string.format("production edges passed: %d\n", ran))
