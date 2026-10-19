--[[
Native onefile extractor compiler smoke test with a minimal staged payload.

Author:
    WaterRun
File:
    onefile_compile_native.lua
Date:
    2026-07-14
Updated:
    2026-10-20
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local bundler = require("luainstaller.bundler")
local fs = require("luainstaller.fs")
local onefile = require("luainstaller.onefile")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")

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
        onefile_mode = "extract",
    })
    bundler.bundleOnedir = original
    return result
end
local extractor_source, extractor_payload
local original_compile = toolchain.compileStandalone
if suffix == ".exe" then
    toolchain.compileStandalone = function(compiler, source, ...)
        if path.basename(source) == "extractor.c" then
            extractor_source = assert(fs.readRegularFile(source))
            extractor_payload = assert(fs.readRegularFile(path.join(path.dirname(source), "payload.inc")))
        end
        return original_compile(compiler, source, ...)
    end
end
local called, built = pcall(build)
toolchain.compileStandalone = original_compile
assert(called, built)
local diagnostic = built.error and table.concat({
    tostring(built.error.message or "onefile extractor compile failed"),
    tostring(built.error.command or ""),
    tostring(built.error.output or built.error.cause or ""),
}, "\n") or "onefile extractor compile failed"
assert(built.ok, diagnostic)
assert(fs.pathType(out) == "file")
if suffix == ".exe" then
    assert(extractor_source and extractor_payload, "extractor source was not captured")
    local probe_source, probe = path.join(root, "extractor-pin.c"), path.join(root, "extractor-pin.exe")
    assert(fs.writeFile(path.join(root, "payload.inc"), extractor_payload))
    assert(fs.writeFile(probe_source, "#define main luai_extractor_entrypoint\n"
        .. extractor_source .. "\n#undef main\n" .. [[
int main(int argc, char **argv) {
    struct luai_pinned_objects pins;
    BOOL moved;
    DWORD error;
    if (argc != 3) return 2;
    memset(&pins, 0, sizeof(pins));
    if (luai_open_pinned_directory(argv[1], 0, &pins) != 0) return 3;
    moved = MoveFileA(argv[1], argv[2]);
    error = GetLastError();
    luai_close_pins(&pins);
    if (moved && !MoveFileA(argv[2], argv[1])) return 4;
    if (moved) { fputs("an extractor ancestor was moved while reserved\n", stderr); return 5; }
    if (error != ERROR_SHARING_VIOLATION && error != ERROR_ACCESS_DENIED) return 6;
    puts("extractor parent reservation blocks replacement");
    return 0;
}
]]))
    local compiler = assert(toolchain.resolveCompiler({}))
    local compiled, compiler_output = toolchain.compileStandalone(compiler, probe_source, probe, {work_dir=root})
    assert(compiled, compiler_output)
    local reserved, moved = path.join(root, "reserved-parent"), path.join(root, "moved-parent")
    assert(fs.makeDirectory(reserved))
    local protected, output = process.outputCommand(probe, {reserved, moved})
    assert(protected, output)
    assert(fs.pathType(reserved) == "directory" and fs.pathType(moved) == "missing")
end
local first_bytes = assert(fs.readRegularFile(out))
assert(fs.removeFile(out))
local rebuilt = build()
assert(rebuilt.ok, rebuilt.error and rebuilt.error.message or "second onefile build failed")
local second_bytes = assert(fs.readRegularFile(out))
if second_bytes ~= first_bytes then
    local function littleU32(bytes, index)
        if index < 1 or index + 3 > #bytes then return nil end
        local first, second, third, fourth = bytes:byte(index, index + 3)
        return first + second * 0x100 + third * 0x10000 + fourth * 0x1000000
    end
    local function peTimestamp(bytes)
        if bytes:sub(1, 2) ~= "MZ" then return nil end
        local pe_offset = littleU32(bytes, 0x3c + 1)
        if not pe_offset or bytes:sub(pe_offset + 1, pe_offset + 4) ~= "PE\0\0" then
            return nil
        end
        return littleU32(bytes, pe_offset + 8 + 1)
    end
    local first_difference
    for index = 1, math.min(#first_bytes, #second_bytes) do
        if first_bytes:byte(index) ~= second_bytes:byte(index) then
            first_difference = index
            break
        end
    end
    first_difference = first_difference or math.min(#first_bytes, #second_bytes) + 1
    local first_timestamp = peTimestamp(first_bytes)
    local second_timestamp = peTimestamp(second_bytes)
    error(string.format(
        "native onefile extractor is not byte reproducible: first-difference=%d "
            .. "sizes=%d/%d PE-timestamps=%s/%s",
        first_difference,
        #first_bytes,
        #second_bytes,
        first_timestamp and string.format("0x%08x", first_timestamp) or "n/a",
        second_timestamp and string.format("0x%08x", second_timestamp) or "n/a"
    ), 0)
end
assert(fs.removeTree(root))

print("native onefile extractor compile ok")
