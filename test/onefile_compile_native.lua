--[[
Native onefile extractor compiler smoke test with a minimal staged payload.

Author:
    WaterRun
File:
    onefile_compile_native.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local bundler = require("luainstaller.bundler")
local fs = require("luainstaller.fs")
local onefile = require("luainstaller.onefile")
local path = require("luainstaller.path")

local root = assert(fs.makePrivateDirectory("onefile-compile"))
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
local out = path.join(root, "extractor" .. suffix)
local original = bundler.bundleOnedir
local function build()
    bundler.bundleOnedir = function(opts)
        assert(fs.makeDirectory(path.join(opts.out, ".luai")))
        local inner = path.join(opts.out, "inner" .. suffix)
        assert(fs.writeFile(inner, "minimal native extractor payload\n"))
        assert(fs.setExecutable(inner))
        return { ok = true, executable = inner, manifest = opts.manifest }
    end
    local result = onefile.bundleOnefile({
        entry = "test/runtime_bundle/main.lua",
        out = out,
    })
    bundler.bundleOnedir = original
    return result
end
local built = build()
local diagnostic = built.error and table.concat({
    tostring(built.error.message or "onefile extractor compile failed"),
    tostring(built.error.command or ""),
    tostring(built.error.output or built.error.cause or ""),
}, "\n") or "onefile extractor compile failed"
assert(built.ok, diagnostic)
assert(fs.pathType(out) == "file")
local first_bytes = assert(fs.readRegularFile(out))
assert(fs.removeFile(out))
local rebuilt = build()
assert(rebuilt.ok, rebuilt.error and rebuilt.error.message or "second onefile build failed")
assert(fs.readRegularFile(out) == first_bytes,
    "native onefile extractor is not byte reproducible")
assert(fs.removeTree(root))

print("native onefile extractor compile ok")
