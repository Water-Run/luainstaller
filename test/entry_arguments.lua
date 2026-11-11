--[[
Entry chunks receive application varargs in discovery and generated programs.

Author:
    WaterRun
File:
    entry_arguments.lua
Date:
    2026-11-11
Updated:
    2026-11-11
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local runtime = require("luainstaller.runtime")
local cgen = require("luainstaller.cgen")
local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local embedded = assert(compat.loadText(cgen.runtimeSource .. "\nreturn run", "@entry-arguments"))()
local cases = {{}, {"alpha"}, {"alpha", "", "--literal", "值"}}
local source = [[
local values = {...}
assert(select('#', ...) == #arg, 'entry vararg count differs from arg')
for i = 1, #arg do assert(values[i] == arg[i], 'entry vararg value differs from arg') end
return select('#', ...), ..., nil, false
]]
for _, run in ipairs({runtime.run, embedded}) do
    for _, arguments in ipairs(cases) do
        local old_arg = arg
        local searchers = package.searchers or package.loaders
        local count = #searchers
        local returned = compat.pack(run({entry={path="main.lua", source=source}}, arguments, "app"))
        assert(returned[1] == #arguments, "entry did not receive application arguments")
        assert(returned[returned.n] == false and returned[returned.n - 1] == nil)
        assert(arg == old_arg and #searchers == count, "entry state was not restored")
    end
    local previous = {old=true}
    package.loaded.entry_arguments_module = previous
    local payload = {entry={path="main.lua", source=[[require('entry_arguments_module'); error('entry-test-error')]]},
        modules={entry_arguments_module={path="module.lua", source=[[local name, data = ...; assert(name == 'entry_arguments_module');
            if _VERSION ~= 'Lua 5.1' then assert(data == 'module.lua') end; return false]]}}}
    local old_arg = arg
    local count = #(package.searchers or package.loaders)
    local ok, message = pcall(run, payload, {"application-arg"}, "app")
    assert(not ok and tostring(message):find("entry-test-error", 1, true), tostring(message))
    assert(package.loaded.entry_arguments_module == previous and arg == old_arg
        and #(package.searchers or package.loaders) == count, "failed entry leaked state")
    package.loaded.entry_arguments_module = nil
end

local root = assert(fs.makePrivateDirectory("entry-arguments"))
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    local module = path.join(root, "choice.lua")
    assert(fs.writeFile(module, "assert((...) == 'choice'); return true\n"))
    assert(fs.writeFile(entry, [[
local values = {...}
assert(select('#', ...) == #arg, 'entry vararg count differs from arg')
for i = 1, #arg do
    assert(values[i] == arg[i], 'entry vararg value differs from arg')
    print(i .. ':' .. #values[i] .. ':' .. values[i])
end
require('choice')
]]))
    local arguments = cases[3]
    local direct_arguments = {entry}
    for _, value in ipairs(arguments) do direct_arguments[#direct_arguments + 1] = value end
    local ran, expected = process.outputCommand(harness.lua_command(), direct_arguments,
        {LUA_PATH=root .. "/?.lua;;", LUA_CPATH=""})
    assert(ran, expected)
    local outputs = {}
    for _, mode in ipairs({"onedir", "extract", "no-extract"}) do
        local built = api.bundle({entry=entry, out=path.join(root, "app-" .. mode),
            mode=mode == "onedir" and "onedir" or "onefile",
            onefile_mode=mode == "onedir" and "auto" or mode})
        assert(built.ok, built.error and (built.error.message .. "\n" .. tostring(built.error.output)))
        outputs[#outputs + 1] = built.executable
    end
    local trace = path.join(root, "trace.lua")
    assert(fs.writeFile(trace, "local name = ...; assert(name == 'choice', 'missing entry vararg'); require(name)\n"))
    local analyzed = api.analyze({entry=trace, discovery_mode="runtime", run_args={"choice", "", "--literal"},
        lua=harness.lua_command()})
    assert(analyzed.ok, analyzed.error and (analyzed.error.message .. "\n" .. tostring(analyzed.error.output)))
    assert(#analyzed.dependencies.scripts == 1 and analyzed.dependencies.scripts[1] == module,
        "runtime discovery lost the module selected through entry varargs")
    for _, program in ipairs({"luai", "luainstaller"}) do
        local cli_ok, cli_output = harness.invoke_cli(program, program == "luai"
            and {"-a", trace, "-d", "runtime", "--", "choice", "", "--literal"}
            or {"analyze", trace, "-d", "runtime", "--", "choice", "", "--literal"})
        assert(cli_ok == 0, cli_output)
    end
    assert(fs.removeFile(entry))
    assert(fs.removeFile(module))
    assert(fs.removeFile(trace))
    for _, executable in ipairs(outputs) do
        local ok, output = process.outputCommand(executable, arguments, {PATH="", LUA_PATH="", LUA_CPATH=""})
        assert(ok and output == expected, "generated program arguments differ from direct Lua: " .. tostring(output))
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("entry application arguments ok")
