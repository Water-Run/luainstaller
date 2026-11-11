--[[
The complete benchmark driver reports missing coverage and enforces deadlines.

Author:
    WaterRun
File:
    benchmark_driver.lua
Date:
    2026-11-11
Updated:
    2026-11-11
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
assert(package.config:sub(1, 1) == "/", "benchmark driver requires a POSIX host")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("benchmark-driver", "/tmp"))
local failures = {}
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local function script(name, source)
    local filename = path.join(root, name)
    assert(fs.writeFile(filename, "#!/bin/sh\n" .. source))
    assert(fs.setExecutable(filename))
    return filename
end
local fake = script("luai", [[
entry= out= mode= discovery=
while [ "$#" -gt 0 ]; do
 case "$1" in
 -o) out=$2; shift 2;;
 -d) discovery=$2; shift 2;;
 --dir) mode=dir; shift;;
 --file) mode=file; shift;;
 *.lua) entry=$1; shift;;
 *) shift;;
 esac
done
case "$entry:$discovery" in
 */dynamic-require/main.lua:static)
  case "$BENCH_SCENARIO" in
   unexpected) exit 0;;
   wrong-error) echo 'error: ToolchainError: wrong failure' >&2; exit 1;;
   *) echo "error: DynamicRequireError: computed require" >&2; exit 1;;
  esac;;
 */neovim-wrapper/main.lua:runtime)
  if [ "$BENCH_SCENARIO" = hang ]; then
   trap '' TERM
   sleep 30 &
   echo "$!" > "$BENCH_CHILD_PID"
   wait
  fi;;
esac
if [ -n "$out" ]; then
 if [ "$mode" = dir ]; then mkdir -p "$out"; out="$out/$(basename "$out")"; fi
 printf '#!/bin/sh\nexit 0\n' > "$out"
 chmod +x "$out"
fi
]])
local rocks = script("luarocks", 'test "$BENCH_SCENARIO" != install-fail\n')
assert(fs.makeDirectory(path.join(root, "bin")))
local git = script("bin/git", [[
[ "$BENCH_SCENARIO" != clone-fail ] || exit 42
for directory do :; done
case "$directory" in
 */luacheck) mkdir -p "$directory/src/luacheck"; printf 'return true\n' > "$directory/src/luacheck/parser.lua";;
 */neovim) mkdir -p "$directory/runtime/lua"; printf 'return true\n' > "$directory/runtime/lua/probe.lua";;
esac
]])
script("bin/timeout", "exit 127\n")
local serial = 0
local function run(scenario, options)
    serial = serial + 1
    local arguments = {"tools/benchmark-real-world.sh", "--work-root", root .. "/run-" .. serial,
        "--fake-scales", "1", "--neovim-timeout", "1"}
    for _, value in ipairs(options or {}) do arguments[#arguments + 1] = value end
    local ok, output, status = process.outputCommand("bash", arguments, {
        LUA_BIN=harness.lua_command(), LUAI_BIN=fake, LUAROCKS_BIN=rocks,
        FAKE_SCALES="1", BENCH_SCENARIO=scenario, BENCH_CHILD_PID=root .. "/child.pid",
        PATH=root .. "/bin:" .. (os.getenv("PATH") or ""), KEEP_WORKSPACE="0",
        SKIP_NATIVE="0", SKIP_EXTERNAL="0", LUAI_CMD_TIMEOUT="30",
    }, {timeout_seconds=120, max_output_bytes=65536})
    assert(status.reason ~= "timeout", "benchmark driver itself hung: " .. output)
    return ok, output, status
end
local function summary(output)
    local filename = output:match("summary file: ([^\r\n]+)")
    assert(filename and fs.isRegularFile(filename), "benchmark summary did not survive exit: " .. output)
    return assert(fs.readFile(filename)), path.dirname(filename)
end
check("success without GNU timeout and retained logs", function()
    local ok, output = run("success")
    assert(ok, output)
    local text, directory = summary(output)
    assert(text:find("all cases completed", 1, true), text)
    assert(fs.isRegularFile(path.join(directory, "logs/hello_world-analyze.log")), "command evidence is missing")
    assert(fs.removeTree(directory))
end)
for _, scenario in ipairs({"install-fail", "clone-fail", "unexpected", "wrong-error"}) do
    check(scenario, function()
        local ok, output = run(scenario)
        assert(not ok, "benchmark accepted " .. scenario .. ": " .. output)
        local _, directory = summary(output)
        assert(fs.removeTree(directory))
    end)
end
check("explicitly reduced coverage", function()
    local ok, output = run("success", {"--skip-external", "--skip-native"})
    assert(ok and output:find("incomplete", 1, true), output)
    local _, directory = summary(output)
    assert(fs.removeTree(directory))
end)
check("comma and space scale lists", function()
    for _, scales in ipairs({"1,2", "1 2", "1, 2", "1\n2"}) do
        local ok, output = run("success", {"--fake-scales", scales, "--keep-workspace"})
        assert(ok and output:find("### fake_1\n", 1, true) and output:find("### fake_2\n", 1, true), output)
        local workspace = assert(output:match("workspace kept: ([^\r\n]+)"))
        for _, n in ipairs({1, 2}) do
            for i = 1, n do
                assert(fs.isRegularFile(string.format("%s/fake-%d/module_%04d.lua", workspace, n, i)))
            end
        end
        local _, directory = summary(output)
        assert(fs.removeTree(workspace))
        if fs.pathType(directory) == "directory" then assert(fs.removeTree(directory)) end
    end
end)
check("invalid scales", function()
    for _, scales in ipairs({"0", "-1", "oops", "1,,2", "1,", ""}) do
        local ok, output = run("success", {"--fake-scales", scales})
        assert(not ok, "invalid scale list accepted: " .. scales .. "\n" .. output)
    end
end)
check("deadline and descendant cleanup", function()
    local ok, output = run("hang")
    assert(not ok, "hanging exploratory case was accepted: " .. output)
    local pid = assert(fs.readFile(root .. "/child.pid")):match("^%d+")
    local active, state = process.outputCommand("ps", {"-p", pid, "-o", "stat="})
    assert(not active or state:match("^%s*Z"), "timed out child is still running: " .. state)
    local _, directory = summary(output)
    assert(fs.removeTree(directory))
end)
assert(fs.removeTree(root))
assert(#failures == 0, table.concat(failures, "\n"))
print("benchmark driver failure boundaries ok")
