--[[
Pinned POSIX source downloads retain identity across a transport fallback.

Author:
    WaterRun
File:
    source_download.lua
Date:
    2026-11-12
Updated:
    2026-11-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local process = require("luainstaller.process")
local hash = require("luainstaller.hash")
local root = assert(fs.makePrivateDirectory("source-download"))
local source = harness.read_file("tools/test-lua-versions.sh")
local definitions = {}
for _, name in ipairs({"owned_regular_file", "sha256_file", "verify_sha256", "stage_source"}) do
    definitions[#definitions + 1] = assert(source:match("\n(" .. name .. "%(%)[^\n]*\n.-\n})"), name)
end
local curl = root .. "/curl"
assert(fs.writeFile(curl, [[#!/bin/sh
out= previous=
for value do
    [ "$previous" != -o ] || out=$value
    previous=$value
done
case "$previous" in
    */primary) exit 28;;
    */mirror)
        [ "$DOWNLOAD_SCENARIO" != failure ] || exit 28
        if [ "$DOWNLOAD_SCENARIO" = mismatch ]; then printf wrong > "$out"
        else printf pinned-source-fixture > "$out"; fi;;
    *) exit 2;;
esac
]]))
assert(fs.setExecutable(curl))
local called, failure = pcall(function()
    for _, scenario in ipairs({"success", "mismatch", "failure"}) do
        local driver = root .. "/" .. scenario .. ".sh"
        local destination = root .. "/" .. scenario
        assert(fs.writeFile(driver, "#!/bin/sh\nset -eu\n" .. table.concat(definitions, "\n")
            .. "\nSOURCE_CACHE=" .. process.shellQuote(root) .. "\nstage_source "
            .. process.shellQuote(scenario) .. " https://invalid.example/primary "
            .. process.shellQuote(hash.sha256("pinned-source-fixture"))
            .. " https://invalid.example/mirror\n"))
        local ok, output = process.outputCommand("sh", {driver}, {
            DOWNLOAD_SCENARIO=scenario, PATH=root .. ":" .. (os.getenv("PATH") or ""),
        })
        if scenario == "success" then
            assert(ok, output)
            assert(fs.readFile(destination) == "pinned-source-fixture")
        else
            assert(not ok and fs.pathType(destination) == "missing", "invalid source was published: " .. output)
        end
        local files = assert(fs.listTree(root))
        for _, item in ipairs(files) do assert(not item.path:find(".part.", 1, true), "partial source left behind") end
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("pinned source transport fallback ok")
