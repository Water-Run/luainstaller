--[[
Distribution license, notice, and corresponding-source contract.

Author:
    WaterRun
File:
    distribution_licenses.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")

local root = assert(fs.makePrivateDirectory("distribution-licenses"))
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
local canonical = {
    [".luai/licenses/Lua-MIT.txt"] = "LICENSES/Lua-MIT.txt",
    [".luai/licenses/LGPL-3.0-or-later.txt"] = "LICENSE",
    [".luai/licenses/GPL-3.0-or-later.txt"] = "LICENSES/GPL-3.0-or-later.txt",
    ["THIRD_PARTY_NOTICES.md"] = "THIRD_PARTY_NOTICES.md",
    [".luai/build/RELINKING.adoc"] = "docs/RELINKING.adoc",
    [".luai/build/generate-onefile-payload.lua"] =
        "tools/generate-onefile-payload.lua",
}

local function cleanup()
    if fs.pathType(root) == "directory" then fs.removeTree(root) end
end

local function read(relative_root, relative)
    return assert(fs.readRegularFile(path.join(relative_root, relative)), relative)
end

local function assertContains(content, needle, label)
    assert(content:find(needle, 1, true),
        tostring(label or "content") .. " does not contain " .. needle)
end

local function assertDistribution(bundle_root, expect_extractor)
    assertContains(read(bundle_root, ".luai/licenses/Lua-MIT.txt"),
        "Permission is hereby granted, free of charge", "Lua license")
    assertContains(read(bundle_root, ".luai/licenses/LGPL-3.0-or-later.txt"),
        "GNU LESSER GENERAL PUBLIC LICENSE", "LGPL license")
    assertContains(read(bundle_root, ".luai/licenses/GPL-3.0-or-later.txt"),
        "GNU GENERAL PUBLIC LICENSE", "GPL license")
    local notices = read(bundle_root, "THIRD_PARTY_NOTICES.md")
    assertContains(notices, "Lua 5.4.8", "third-party notices")
    assertContains(notices, "https://www.lua.org/ftp/lua-5.4.8.tar.gz",
        "third-party source location")
    assertContains(read(bundle_root, ".luai/build/RELINKING.adoc"),
        "Relinking", "relinking instructions")
    assert(fs.pathType(path.join(bundle_root, ".luai/build/launcher.c")) == "file",
        "generated launcher source is missing")
    for destination, source in pairs(canonical) do
        assert(read(bundle_root, destination) == assert(fs.readRegularFile(source)),
            destination .. " differs from its canonical source")
    end
    if expect_extractor then
        local extractor = read(bundle_root, ".luai/build/extractor.c")
        assertContains(extractor, "exact extractor translation unit",
            "onefile extractor corresponding source")
        assertContains(extractor, '#include "payload.inc"',
            "onefile extractor payload interface")
    end
end

local function assertManifest(bundle_root)
    local manifest = assert(loadfile(path.join(bundle_root, ".luai/manifest.lua")))()
    assert(#manifest.distribution_files == 6,
        "manifest distribution material count changed")
    local seen = {}
    for _, record in ipairs(manifest.distribution_files) do
        assert(canonical[record.destination_path],
            "manifest contains an unknown distribution material")
        assert(record.source_path == nil and record.source_id == nil,
            "manifest leaks a distribution material source path")
        assert(record.content_hash == hash.sha256(read(bundle_root, record.destination_path)),
            "manifest distribution material hash mismatch")
        assert(not seen[record.destination_path], "duplicate distribution material record")
        seen[record.destination_path] = true
    end
    for destination in pairs(canonical) do
        assert(seen[destination], "manifest omits " .. destination)
    end
end

local called, failure = xpcall(function()
    assert(hash.sha256(assert(fs.readRegularFile("LICENSES/Lua-MIT.txt")))
        == "8eabfd4cf1755e7597d98eea884447f94e160d5950af35c291f2e649ed797c19",
        "Lua license differs from the verified Lua 5.4.8 text")
    assert(hash.sha256(assert(fs.readRegularFile("LICENSES/GPL-3.0-or-later.txt")))
        == "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986",
        "GPLv3 text differs from the verified GNU copy")
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, [[print("distribution license fixture")]]))

    local onedir = path.join(root, "onedir", "app")
    local onefile = path.join(root, "onefile", "app" .. suffix)
    local onedir_result = require("luainstaller").bundle({
        entry = entry,
        out = onedir,
        mode = "onedir",
    })
    assert(onedir_result.ok, onedir_result.error and onedir_result.error.message)
    assertDistribution(onedir, false)
    assertManifest(onedir)

    local onefile_result = require("luainstaller").bundle({
        entry = entry,
        out = onefile,
        mode = "onefile",
    })
    assert(onefile_result.ok, onefile_result.error and onefile_result.error.message)
    local cache = path.join(root, "cache")
    assert(fs.makeDirectory(cache))
    local clean_path = path.join(root, "empty-path")
    assert(fs.makeDirectory(clean_path))
    local ran, output = process.outputCommand(onefile_result.executable, {}, {
        PATH = clean_path,
        TMPDIR = cache,
        TEMP = cache,
        TMP = cache,
        LUA_PATH = "",
        LUA_CPATH = "",
        LUA_INIT = "",
        LUA_INIT_5_1 = "",
        LUA_INIT_5_2 = "",
        LUA_INIT_5_3 = "",
        LUA_INIT_5_4 = "",
        LUA_INIT_5_5 = "",
    })
    assert(ran, output)
    assertContains(output, "distribution license fixture", "onefile output")

    local inventory = assert(fs.listTree(cache))
    local extracted_root
    local suffix_path = ".luai/licenses/Lua-MIT.txt"
    for _, item in ipairs(inventory) do
        local normalized = path.normalize(item.path)
        if item.type == "file" and normalized:sub(-#suffix_path) == suffix_path then
            extracted_root = path.join(cache, normalized:sub(1, #normalized - #suffix_path - 1))
            break
        end
    end
    assert(extracted_root, "onefile did not extract its distribution notices")
    assertDistribution(extracted_root, true)
    assertManifest(extracted_root)
    assert(read(extracted_root, ".luai/build/launcher.c")
            == read(onedir, ".luai/build/launcher.c"),
        "onefile and onedir launcher sources differ")

    local build_dir = path.join(extracted_root, ".luai/build")
    local regenerated_include = path.join(build_dir, "payload.inc")
    local generated, generator_output = process.outputCommand(
        harness.lua_command(),
        {
            path.join(build_dir, "generate-onefile-payload.lua"),
            extracted_root,
            regenerated_include,
        }
    )
    assert(generated, generator_output)
    local regenerated_id = generator_output:match("([0-9a-f]+)")
    assert(regenerated_id and #regenerated_id == 64,
        "payload generator did not report a SHA-256 identifier")
    local compiler, compiler_err = toolchain.resolveCompiler({})
    assert(compiler, compiler_err and compiler_err.error.message)
    local profile = assert(platform.profile({}))
    local relinked = path.join(root, "relinked-onefile" .. suffix)
    local compiled, compile_output, compile_command = toolchain.compileStandalone(
        compiler,
        path.join(build_dir, "extractor.c"),
        relinked,
        { work_dir = build_dir }
    )
    assert(compiled, tostring(compile_command) .. "\n" .. tostring(compile_output))
    if profile.target_os ~= "windows" then assert(fs.setExecutable(relinked)) end
    local relink_cache = path.join(root, "relinked-cache")
    assert(fs.makeDirectory(relink_cache))
    local relink_ran, relink_output = process.outputCommand(relinked, {}, {
        PATH = clean_path,
        TMPDIR = relink_cache,
        TEMP = relink_cache,
        TMP = relink_cache,
        LUA_PATH = "",
        LUA_CPATH = "",
        LUA_INIT = "",
        LUA_INIT_5_4 = "",
    })
    assert(relink_ran, relink_output)
    assertContains(relink_output, "distribution license fixture", "relinked onefile")

    local lua_license = path.join(extracted_root, ".luai/licenses/Lua-MIT.txt")
    local expected_lua_license = assert(fs.readRegularFile("LICENSES/Lua-MIT.txt"))
    assert(fs.writeFile(lua_license, string.rep("X", #expected_lua_license)))
    local repaired, repaired_output = process.outputCommand(onefile_result.executable, {}, {
        PATH = clean_path,
        TMPDIR = cache,
        TEMP = cache,
        TMP = cache,
        LUA_PATH = "",
        LUA_CPATH = "",
        LUA_INIT = "",
        LUA_INIT_5_4 = "",
    })
    assert(repaired, repaired_output)
    assert(read(extracted_root, ".luai/licenses/Lua-MIT.txt") == expected_lua_license,
        "onefile cache did not repair a tampered license file")

    local bytes = assert(fs.readRegularFile(onefile_result.executable))
    assertContains(bytes, "GNU LESSER GENERAL PUBLIC LICENSE", "onefile bytes")
    assertContains(bytes, "Permission is hereby granted, free of charge", "onefile bytes")
    assertContains(bytes, regenerated_id, "original onefile payload identifier")

    if suffix == "" then
        local reserved = require("luainstaller").bundle({
            entry = entry,
            out = path.join(root, "THIRD_PARTY_NOTICES.md"),
            mode = "onedir",
        })
        assert(not reserved.ok and reserved.error.type == "InvalidOptionsError",
            "an executable was allowed to collide with the notice file")
    end
end, function(err)
    return err
end)

cleanup()
assert(called, failure)
print("distribution licenses ok: notices, source, relinking, no-Lua onefile")
