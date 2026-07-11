# Production Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make luainstaller fail closed across discovery, generation, output ownership, onefile extraction, installation, logging, and the supported platform test gates.

**Architecture:** Add focused filesystem and hashing primitives, then make every higher layer consume their checked results. Preserve the public API shape while upgrading manifest/ownership data to v2 and adding regression tests that exercise real bundles, processes, compilers, permissions, races, and remote-script contracts.

**Tech Stack:** Lua 5.4, POSIX shell, C11, GCC, Clang, MinGW, Wine, LuaRocks, Git worktrees.

## Global Constraints

- Lua ABI is exactly 5.4; the rockspec range is `>= 5.4, < 5.5`.
- Entry-rooted static resolution and the `./`/`../` resolver extension remain supported.
- Existing v1 generated directories are refused, never silently upgraded.
- New manifests and ownership markers use SHA-256 and schema/marker version 2.
- Manual includes accept readable Lua source files only.
- Embedded Lua aliases share one source record; conflicting owners fail.
- Windows-generated names are portable and target collisions are case-insensitive.
- Remote destructive paths are restricted to normalized `luainstaller-*` temporary roots.
- No force push, release tag, or staging of the primary checkout's `.review-patches/` is allowed.

---

### Task 1: Edge runner, checked I/O, and SHA-256

**Files:**
- Create: `test/production_edges.lua`
- Create: `src/fs.lua`
- Create: `src/hash.lua`
- Modify: `test/support/harness.lua`
- Modify: `test/smoke_all.lua`
- Modify: `src/cli.lua`
- Modify: `tools/install-source.sh`
- Modify: `luainstaller-1.0.0-1.rockspec`

**Interfaces:**
- Produces: `fs.readFile(path) -> content|nil, message|nil`; `fs.writeFile(path, content) -> true|nil, message|nil`; `hash.sha256(content) -> 64 lowercase hex`; `hash.fnv1a32(content) -> 8 lowercase hex`.
- Produces: `EDGE_FILTER=name-fragment lua test/production_edges.lua` for focused red/green cycles.

- [ ] **Step 1: Add the test runner and failing hash/I/O tests**

```lua
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local shell_quote = harness.shell_quote
local file_exists = harness.file_exists
local read_file = harness.read_file
local write_file = harness.write_file
local make_temp_dir = harness.make_temp_dir
local remove_tree = harness.remove_tree
local make_directory = harness.mkdir
local assert_contains = harness.assert_contains
local assert_not_contains = harness.assert_not_contains
local function command_ok(command)
    local status = os.execute(command .. " >/dev/null 2>&1")
    return status == true or status == 0
end
local function command_output(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a") or ""
    local ok = pipe:close()
    assert(ok == true, "command failed: " .. command .. "\n" .. output)
    return output
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function assert_equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %q, got %q", label, expected, actual))
end

test("sha256 known vectors", function()
    local hash = require("luainstaller.hash")
    assert_equal(hash.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty")
    assert_equal(hash.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc")
end)

test("checked write reports flush or close failure", function()
    local fs = require("luainstaller.fs")
    local probe = package.config:sub(1, 1) == "/" and io.open("/dev/full", "wb") or nil
    if probe then
        probe:close()
        local ok = fs.writeFile("/dev/full", "not silently successful")
        assert(ok == nil)
    end
end)

local filter = os.getenv("EDGE_FILTER")
local ran = 0
for _, item in ipairs(tests) do
    if not filter or item.name:find(filter, 1, true) then
        item.fn()
        ran = ran + 1
        print("ok - " .. item.name)
    end
end
assert(ran > 0, "EDGE_FILTER selected no tests")
print(string.format("production edges passed: %d", ran))
```

- [ ] **Step 2: Verify the new tests fail because the modules are absent**

Run: `EDGE_FILTER=sha256 lua test/production_edges.lua`

Expected: failure loading `luainstaller.hash`, not a fixture or syntax error.

- [ ] **Step 3: Implement the focused primitives and register both modules**

```lua
-- src/fs.lua contract
function M.readFile(path)
    local handle, open_err = io.open(path, "rb")
    if not handle then return nil, tostring(open_err) end
    local content, read_err = handle:read("*a")
    local closed, close_err = handle:close()
    if content == nil then return nil, tostring(read_err or "read failed") end
    if not closed then return nil, tostring(close_err or "close failed") end
    return content
end

function M.writeFile(path, content)
    local handle, open_err = io.open(path, "wb")
    if not handle then return nil, tostring(open_err) end
    local wrote, write_err = handle:write(content or "")
    local flushed, flush_err = handle:flush()
    local closed, close_err = handle:close()
    if not wrote or not flushed or not closed then
        return nil, tostring(write_err or flush_err or close_err or "write failed")
    end
    return true
end
```

Implement SHA-256 with 32-bit masked Lua 5.4 bitwise operations, 64 round
constants, big-endian padding, and eight-word output. Add preload/module list
entries everywhere the existing internal modules are registered or installed.

- [ ] **Step 4: Verify focused and baseline tests pass**

Run: `EDGE_FILTER=sha256 lua test/production_edges.lua && lua test/contract_docs.lua`

Expected: both commands exit 0 with no warnings from the new modules.

- [ ] **Step 5: Commit the primitive layer**

```sh
git add src/fs.lua src/hash.lua src/cli.lua test/production_edges.lua \
  test/support/harness.lua test/smoke_all.lua tools/install-source.sh \
  luainstaller-1.0.0-1.rockspec
git commit -m "feat: add checked IO and SHA-256 primitives"
```

### Task 2: Root-safe paths and public input validation

**Files:**
- Modify: `src/path.lua`
- Modify: `src/init.lua`
- Modify: `src/discovery.lua`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Produces: `path.join(left, right)`, corrected `dirname`, `absolute`, `isWithin`, and `isSafeRelative`.
- Produces: structured API failures for NUL-containing options, directories, devices, unreadable sources, non-finite limits, and non-Lua manual includes.

- [ ] **Step 1: Add failing path and input tests**

```lua
test("path roots and safe relatives", function()
    local path = require("luainstaller.path")
    assert_equal(path.dirname("/main.lua"), "/", "POSIX root parent")
    assert_equal(path.dirname("C:/main.lua"), "C:/", "drive root parent")
    assert_equal(path.join("/", "main.lua"), "/main.lua", "root join")
    assert(path.isWithin("foo/bar", "."))
    assert(not path.isSafeRelative("C:relative"))
    assert(not path.isSafeRelative("trailing/"))
end)

test("API rejects non-file and non-finite inputs", function()
    local luainstaller = require("luainstaller")
    local directory = luainstaller.analyze({ entry = "test" })
    assert(not directory.ok and directory.error.type ~= "LuaInstallerError")
    local infinite = luainstaller.analyze({
        entry = "test/single_file/01_hello_luainstaller.lua",
        max_deps = math.huge,
    })
    assert(not infinite.ok and infinite.error.type == "InvalidOptionsError")
end)
```

- [ ] **Step 2: Verify focused tests fail on the current root and directory behavior**

Run: `EDGE_FILTER=path lua test/production_edges.lua`

Expected: `/main.lua` currently reports `.` as its parent.

- [ ] **Step 3: Implement explicit root cases, safe joining, finite checks, and readable-file validation**

```lua
function M.join(left, right)
    left, right = M.normalize(left), tostring(right or "")
    if M.isAbsolute(right) then return M.normalize(right) end
    if left == "/" or left:match("^%a:/$") or left == "//" then
        return M.normalize(left .. right)
    end
    return M.normalize(left .. "/" .. right)
end

local function validateMaxDeps(opts)
    local value = opts.max_deps
    if value ~= nil and (type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge
        or value < 1 or value ~= math.floor(value)) then
        return invalidOption("max_deps", "max_deps must be a finite positive integer")
    end
end
```

Use checked reads to distinguish directories and read errors. Reject a NUL byte
before any value reaches a shell command. Normalize manual paths to absolute
paths, require a `.lua` suffix, and deduplicate them against automatic paths.

- [ ] **Step 4: Run path/input tests and public contracts**

Run: `EDGE_FILTER=path lua test/production_edges.lua && EDGE_FILTER=API lua test/production_edges.lua && lua test/contract_docs.lua`

Expected: all three commands exit 0.

- [ ] **Step 5: Commit path and validation behavior**

```sh
git add src/path.lua src/init.lua src/discovery.lua test/production_edges.lua
git commit -m "fix: validate source inputs and root paths"
```

### Task 3: Lua syntax validation and require lexer fidelity

**Files:**
- Modify: `src/analyzer.lua`
- Modify: `src/runtime.lua`
- Modify: `src/cgen.lua`
- Modify: `src/init.lua`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Produces: `analyzer.prepareSource(source, path) -> normalized text` and structured `LuaSyntaxError`.
- Produces: lexer records `{name, line, optional}` matching legal Lua literal call syntax.

- [ ] **Step 1: Add the full failing differential table and invalid-source bundle test**

```lua
test("require lexer matches legal Lua literal forms", function()
    local Lexer = require("luainstaller.analyzer").LuaLexer
    local cases = {
        { "require -- line\n 'foo'", "foo", 1 },
        { "require(--[[block]] [=[\nfoo]=])", "foo", 1 },
        { "pcall( --c\n require, --d\n 'foo')", "foo", 2 },
        { "require\f'foo'", "foo", 1 },
        { "require\v'foo'", "foo", 1 },
    }
    for _, case in ipairs(cases) do
        assert(load(case[1], "=fixture", "t", {}))
        local found = Lexer.new(case[1], "fixture.lua"):extractRequires()
        assert_equal(found[1].name, case[2], case[1])
        assert_equal(found[1].line, case[3], case[1] .. " line")
    end
    assert(#Lexer.new("local r=require; if require then return r end", "ref.lua"):extractRequires() == 0)
end)

test("invalid Lua never produces a bundle", function()
    local root = make_temp_dir("invalid-lua")
    write_file(root .. "/main.lua", "local broken =")
    local result = require("luainstaller").bundle({ entry = root .. "/main.lua", out = root .. "/out" })
    assert(not result.ok and result.error.type == "LuaSyntaxError")
    assert(not file_exists(root .. "/out"))
    remove_tree(root)
end)
```

- [ ] **Step 2: Verify failures are the previously reproduced lexer and late-runtime defects**

Run: `EDGE_FILTER=require lua test/production_edges.lua && EDGE_FILTER='invalid Lua' lua test/production_edges.lua`

Expected: comment/long-string cases or invalid-source bundling fail.

- [ ] **Step 3: Implement trivia parsing, literal decoding, start-line retention, and pre-build compilation**

```lua
function LuaLexer:skipTrivia()
    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch:match("%s") then
            self:advanceCharacter()
        elseif ch == "-" and self:peekChar() == "-" then
            self:skipComment()
        else
            return
        end
    end
end

local function validateLuaSource(source, file_path)
    local normalized = prepareSource(source, file_path)
    local loader, syntax_err = load(normalized, "@" .. file_path, "t", {})
    if not loader then error(errors.luaSyntax(file_path, syntax_err)) end
    return normalized
end
```

Move concatenation validation into the parenthesized-argument parser. Make
function declarations and bare identifier references non-calls. Make computed
`pcall(require, value)` raise the same dynamic-require error as computed direct
calls. Remove `bit32` from the builtin table. Keep runtime and generated source
normalization byte-for-byte equivalent, preserving a shebang newline.

- [ ] **Step 4: Run lexer, syntax, smoke, and source-normalization tests**

Run: `EDGE_FILTER=require lua test/production_edges.lua && EDGE_FILTER='invalid Lua' lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: all commands exit 0 and the existing dynamic-require contract remains green.

- [ ] **Step 5: Commit syntax and lexer fixes**

```sh
git add src/analyzer.lua src/runtime.lua src/cgen.lua src/init.lua test/production_edges.lua
git commit -m "fix: match Lua syntax in dependency analysis"
```

### Task 4: Runtime discovery fidelity and in-process isolation

**Files:**
- Modify: `src/discovery.lua`
- Modify: `src/runtime.lua`
- Modify: `src/cgen.lua`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Consumes: checked I/O and validated Lua 5.4 sources.
- Produces: trace records with `loader_path`; payload runs that restore `package.loaded` and return all values.

- [ ] **Step 1: Add failing dynamic-path, partial-trace, and state-restoration tests**

```lua
test("runtime discovery uses the real loader path", function()
    local root = make_temp_dir("runtime-loader")
    make_directory(root .. "/entry")
    make_directory(root .. "/alt")
    write_file(root .. "/entry/choice.lua", "return 'entry'")
    write_file(root .. "/alt/choice.lua", "return 'alt'")
    write_file(root .. "/entry/main.lua", string.format(
        "package.path=%q..package.path; print(require('choice'))", root .. "/alt/?.lua;"))
    local analyzed = require("luainstaller").analyze({
        entry = root .. "/entry/main.lua", discovery_mode = "runtime",
    })
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    assert_equal(analyzed.dependencies.scripts[1], root .. "/alt/choice.lua", "loader path")
    remove_tree(root)
end)

test("runtime run restores bundled module cache entries", function()
    local runtime = require("luainstaller.runtime")
    package.loaded.edge_counter = "outer"
    local payload = {
        entry = { path = "main.lua", source = "return require('edge_counter')" },
        modules = { edge_counter = { path = "edge_counter.lua", source = "return 7" } },
    }
    assert_equal(runtime.run(payload), 7, "payload value")
    assert_equal(package.loaded.edge_counter, "outer", "restored cache")
end)
```

- [ ] **Step 2: Verify the dynamic path resolves to the entry copy and cache test sees `outer`**

Run: `EDGE_FILTER='runtime discovery' lua test/production_edges.lua && EDGE_FILTER='restores bundled' lua test/production_edges.lua`

Expected: both focused tests fail for the confirmed reasons.

- [ ] **Step 3: Capture loader data and implement finally-style cache restoration**

```lua
local packed = table.pack(pcall(original_require, name))
record.loader_path = type(packed[3]) == "string" and packed[3] or nil

local previous = {}
for name in pairs(payload.modules or {}) do
    previous[name] = { present = package.loaded[name] ~= nil, value = package.loaded[name] }
    package.loaded[name] = nil
end
local results = table.pack(pcall(entry_loader))
for name, old in pairs(previous) do
    package.loaded[name] = old.present and old.value or nil
end
```

Serialize a third loader-path field in trace output, require a final completion
record, reject failed write/flush/close, require the selected interpreter to
report `Lua 5.4`, and use the captured file directly when it is readable and
has a supported extension. Mirror the cache/return-value logic in generated
runtime source.

- [ ] **Step 4: Run focused runtime tests and both runtime implementations**

Run: `EDGE_FILTER=runtime lua test/production_edges.lua && lua test/contract_docs.lua && lua test/smoke_all.lua`

Expected: all commands exit 0.

- [ ] **Step 5: Commit runtime fidelity fixes**

```sh
git add src/discovery.lua src/runtime.lua src/cgen.lua test/production_edges.lua
git commit -m "fix: isolate runtime loads and preserve discovery paths"
```

### Task 5: Alias sets, canonical includes, and source-race detection

**Files:**
- Modify: `src/bundler.lua`
- Modify: `src/cgen.lua`
- Modify: `src/discovery.lua`
- Modify: `src/manifest.lua`
- Modify: `src/init.lua`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Produces: `module_names[path] = {alias1=true, alias2=true}` for Lua and native sources.
- Produces: `SourceChangedError` when embedded/copied bytes differ from manifest SHA-256.

- [ ] **Step 1: Add failing two-alias, duplicate-include, and mutation tests**

```lua
test("one source supports every required alias", function()
    for _, mode in ipairs({ "onedir", "onefile" }) do
        for _, order in ipairs({ { "pkg", "pkg.init" }, { "pkg.init", "pkg" } }) do
            local root = make_temp_dir("aliases")
            make_directory(root .. "/pkg")
            write_file(root .. "/pkg/init.lua", "return { value = 19 }")
            write_file(root .. "/main.lua", string.format(
                "local a=require(%q); local b=require(%q); assert(a.value==19 and b.value==19)", order[1], order[2]))
            local result = require("luainstaller").bundle({
                entry = root .. "/main.lua", mode = mode, out = root .. "/out",
            })
            assert(result.ok, result.error and result.error.message)
            assert(command_ok(shell_quote(result.executable)))
            remove_tree(root)
        end
    end
end)

test("manual include deduplicates an automatic dependency", function()
    local result = require("luainstaller").analyze({
        entry = "test/runtime_bundle/main.lua",
        include = { "test/runtime_bundle/greeter.lua" },
    })
    assert(result.ok and #result.dependencies.scripts == 1)
end)
```

Add a compiler-wrapper test that mutates a source after manifest creation and
asserts `SourceChangedError` with no committed output.

- [ ] **Step 2: Verify aliases and duplicate include fail under current last-writer/path spelling behavior**

Run: `EDGE_FILTER=alias lua test/production_edges.lua && EDGE_FILTER='manual include' lua test/production_edges.lua`

Expected: missing alias at runtime and/or duplicate module generation.

- [ ] **Step 3: Emit shared records for alias sets and compare exact hashes at each read/copy boundary**

```lua
local function addAlias(map, source_path, requested)
    source_path = normalizePath(source_path)
    map[source_path] = map[source_path] or {}
    map[source_path][requested] = true
end

local function assertExpectedHash(source_path, content, expected)
    local actual = hash.sha256(content)
    if actual ~= expected then
        error({ type = "SourceChangedError", message = "Source changed during build: " .. source_path,
            source_path = source_path, expected_hash = expected, actual_hash = actual })
    end
end
```

Build one record per source and assign it to every sorted alias in emitted Lua.
Add both package and `.init` names for manual init files. Track alias owners and
target-canonical native destinations before copying. Compare copied destination
bytes with the manifest's source hash.

- [ ] **Step 4: Run aliases in onedir and onefile plus race and baseline suites**

Run: `EDGE_FILTER=alias lua test/production_edges.lua && EDGE_FILTER='Source changed' lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: all commands exit 0.

- [ ] **Step 5: Commit alias and source-stability fixes**

```sh
git add src/bundler.lua src/cgen.lua src/discovery.lua src/manifest.lua src/init.lua test/production_edges.lua
git commit -m "fix: preserve module aliases and source snapshots"
```

### Task 6: Manifest v2 and recursive output ownership

**Files:**
- Modify: `src/manifest.lua`
- Modify: `src/bundler.lua`
- Modify: `src/init.lua`
- Modify: `test/contract_docs.lua`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Produces: manifest `version=2`, `hash_algorithm="sha256"`.
- Produces: recursive marker records `dir<TAB>path` and `file<TAB>path<TAB>sha256` plus an implicit marker file.

- [ ] **Step 1: Add failing recursive-ownership, unreadable-directory, v1-refusal, and hash-schema tests**

```lua
test("rebuild preserves unowned nested content by refusing", function()
    local root = make_temp_dir("nested-owner")
    local out = root .. "/out"
    local opts = { entry = "test/single_file/01_hello_luainstaller.lua", out = out }
    assert(require("luainstaller").bundle(opts).ok)
    write_file(out .. "/.luai/USER-DATA.txt", "must survive")
    local rebuilt = require("luainstaller").bundle(opts)
    assert(not rebuilt.ok and rebuilt.error.type == "InvalidOutputError")
    assert_equal(read_file(out .. "/.luai/USER-DATA.txt"), "must survive", "nested data")
    remove_tree(root)
end)

test("unreadable nonempty output is never classified empty", function()
    if package.config:sub(1, 1) ~= "/" then return end
    local root = make_temp_dir("unreadable-output")
    local out = root .. "/out"
    make_directory(out)
    write_file(out .. "/sentinel", "keep")
    assert(command_ok("chmod 000 " .. shell_quote(out)))
    local result = require("luainstaller").bundle({ entry = "test/single_file/01_hello_luainstaller.lua", out = out })
    assert(not result.ok)
    command_ok("chmod 700 " .. shell_quote(out))
    assert_equal(read_file(out .. "/sentinel"), "keep", "sentinel")
    remove_tree(root)
end)
```

- [ ] **Step 2: Verify nested content is deleted and unreadable output is displaced on current code**

Run: `EDGE_FILTER='nested content' lua test/production_edges.lua && EDGE_FILTER=unreadable lua test/production_edges.lua`

Expected: tests fail with the two audited destructive behaviors.

- [ ] **Step 3: Implement v2 recursive inventory and fail-closed directory inspection**

```lua
local GENERATED_MARKER = "luainstaller-generated-output-v2"

local function listTree(root)
    local ok, raw = commandOutput("find " .. shellQuote(root) .. " -mindepth 1 -print0")
    if not ok then return nil, makeError("FilesystemError", "Cannot inspect output tree", { path = root, output = raw }) end
    local entries = {}
    for absolute in raw:gmatch("([^%z]+)%z") do entries[#entries + 1] = absolute end
    table.sort(entries)
    return entries
end
```

Classify every entry with no symlink following, validate safe relative paths,
record directories and SHA-256 regular files, require exact set equality on
rebuild, and treat any inspection error as a structured refusal. Snapshot the
strong marker hash. Reject v1 before staging. Upgrade manifest platform shape
and contract assertions to version 2.

- [ ] **Step 4: Run ownership, permission, contract, and full onedir tests**

Run: `EDGE_FILTER=output lua test/production_edges.lua && EDGE_FILTER=unreadable lua test/production_edges.lua && lua test/contract_docs.lua && lua test/smoke_all.lua`

Expected: all commands exit 0 and nested sentinel data remains.

- [ ] **Step 5: Commit ownership v2**

```sh
git add src/manifest.lua src/bundler.lua src/init.lua test/contract_docs.lua test/production_edges.lua
git commit -m "fix: verify generated outputs recursively with SHA-256"
```

### Task 7: Target paths, profiles, and Lua ABI checks

**Files:**
- Modify: `src/path.lua`
- Modify: `src/platform.lua`
- Modify: `src/manifest.lua`
- Modify: `src/compat.lua`
- Modify: `src/bundler.lua`
- Modify: `src/launcher.lua`
- Modify: `src/launcher/luai_launcher.c`
- Modify: `test/production_edges.lua`

**Interfaces:**
- Produces: `path.validateTargetRelative(value, target_os)` and `path.targetKey(value, target_os)`.
- Produces: profile `target_arch`; manifest `platform.host` and `platform.target`.

- [ ] **Step 1: Add failing Windows-name/collision, mac-profile, and fake-pkg-config tests**

```lua
test("target paths reject Windows hazards", function()
    local path = require("luainstaller.path")
    for _, value in ipairs({ "CON", "aux.txt", "a:b", "trail. ", "bad?.dll" }) do
        local ok = path.validateTargetRelative(value, "windows")
        assert(not ok, value)
    end
    assert_equal(path.targetKey("A/Core.dll", "windows"), path.targetKey("a/core.DLL", "windows"), "case key")
end)

test("host mac defaults to static launcher profile", function()
    local platform = require("luainstaller.platform")
    local original = platform.detectHost
    platform.detectHost = function() return { os = "macos", arch = "arm64" } end
    package.loaded["luainstaller.manifest"] = nil
    local manifest = require("luainstaller.manifest").build({
        entry = "test/single_file/01_hello_luainstaller.lua", dependencies = { scripts = {}, libraries = {} },
    }).manifest
    assert_equal(manifest.launcher.profile, "static-lua", "mac profile")
    platform.detectHost = original
end)
```

Create a private fake `pkg-config` that returns version 5.3 and valid-looking
flags; assert `ToolchainError` occurs before compiler invocation.

- [ ] **Step 2: Verify target helper is absent, mac profile is shared, and fake ABI is accepted too far**

Run: `EDGE_FILTER='target paths' lua test/production_edges.lua && EDGE_FILTER='host mac' lua test/production_edges.lua && EDGE_FILTER=pkg-config lua test/production_edges.lua`

Expected: all three focused tests fail for the intended missing checks.

- [ ] **Step 3: Implement portable target keys, target metadata, version probing, and compile guard**

```c
#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM != 504
#error "luainstaller requires Lua 5.4 headers"
#endif
```

Reject Windows control/invalid characters, trailing spaces/dots, drive syntax,
and reserved device stems per segment. Lowercase target keys for Windows and
macOS collision checks. Derive mac launcher profile from the resolved profile,
not the raw option. Require `pkg-config --modversion lua` to match `^5%.4` and
propagate host/target architecture separately.

- [ ] **Step 4: Run target tests and strict generated-launcher compilation**

Run: `EDGE_FILTER=target lua test/production_edges.lua && EDGE_FILTER=pkg-config lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: all commands exit 0; GCC-generated launcher test remains warning-free.

- [ ] **Step 5: Commit target and ABI enforcement**

```sh
git add src/path.lua src/platform.lua src/manifest.lua src/compat.lua src/bundler.lua \
  src/launcher.lua src/launcher/luai_launcher.c test/production_edges.lua
git commit -m "fix: enforce target path and Lua ABI contracts"
```

### Task 8: Onefile safety, exact cache checks, and reproducibility

**Files:**
- Modify: `src/onefile.lua`
- Modify: `src/bundler.lua`
- Modify: `test/production_edges.lua`
- Modify: `test/smoke_all.lua`

**Interfaces:**
- Consumes: SHA-256, target path keys, checked writes, manifest v2.
- Produces: byte-identical repeated builds and exact embedded-byte cache verification.

- [ ] **Step 1: Add failing reproducibility, non-executable repair, C-escape, and committed-cleanup tests**

```lua
test("onefile repeats are byte identical", function()
    local root = make_temp_dir("onefile-repro")
    local out = root .. "/app"
    local opts = { entry = "test/single_file/01_hello_luainstaller.lua", mode = "onefile", out = out }
    assert(require("luainstaller").bundle(opts).ok)
    local first = read_file(out)
    assert(os.remove(out))
    assert(require("luainstaller").bundle(opts).ok)
    assert_equal(read_file(out), first, "onefile bytes")
    remove_tree(root)
end)
```

Add an extracted cache file corruption with equal length, an executable-to-
non-executable mode transition fixture, a path containing control byte 11 that
must either round-trip through C escaping or be rejected before compilation,
and injected cleanup failure after successful hard-link publication.

- [ ] **Step 2: Verify repeat builds differ and the sanitizer exposes the null-pointer comparison**

Run: `EDGE_FILTER='byte identical' lua test/production_edges.lua`

Expected: SHA-256 or byte comparison differs between the two current binaries.

- [ ] **Step 3: Implement deterministic payload selection and conforming extractor C**

```c
static int luai_file_matches(const char *path, const unsigned char *expected, size_t expected_size) {
    unsigned char buffer[8192];
    size_t offset = 0;
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    while (offset < expected_size) {
        size_t wanted = expected_size - offset < sizeof(buffer) ? expected_size - offset : sizeof(buffer);
        size_t got = fread(buffer, 1, wanted, file);
        if (got != wanted || memcmp(buffer, expected + offset, got) != 0) { fclose(file); return 0; }
        offset += got;
    }
    if (fgetc(file) != EOF || ferror(file)) { fclose(file); return 0; }
    return fclose(file) == 0;
}
```

Use a null-aware last-separator choice, fixed three-digit octal C escaping,
one-byte fallback arrays for empty files, `FALSE` handle inheritance, and exact
0600/0700 modes. Exclude `.luai/build` and the generated marker. Frame path,
mode, size, and content before SHA-256 payload hashing. Mark post-publication
cleanup failures with `committed=true`.

- [ ] **Step 4: Run reproducibility/cache tests and strict GCC/Clang sanitizer builds**

Run: `EDGE_FILTER=onefile lua test/production_edges.lua && lua test/smoke_all.lua`

Then compile captured extractor C with both compilers using
`-std=c11 -Wall -Wextra -Werror -pedantic`; run the Clang build with
`-fsanitize=address,undefined -fno-omit-frame-pointer`.

Expected: identical binaries, exact cache repair, and zero compiler/sanitizer diagnostics.

- [ ] **Step 5: Commit onefile hardening**

```sh
git add src/onefile.lua src/bundler.lua test/production_edges.lua test/smoke_all.lua
git commit -m "fix: make onefile extraction exact and reproducible"
```

### Task 9: Concurrent crash-safe logging

**Files:**
- Modify: `src/logger.lua`
- Modify: `test/production_edges.lua`
- Modify: `test/contract_docs.lua`

**Interfaces:**
- Produces: five-second lock acquisition, 120-second stale recovery, owner-token release, atomic/backup log switch.

- [ ] **Step 1: Add failing 60-process retention and write-failure preservation tests**

```lua
test("logger retains concurrent writers", function()
    local root = make_temp_dir("logger-concurrency")
    local workers = {}
    for i = 1, 60 do
        workers[#workers + 1] = string.format(
            "HOME=%s lua -e %s &", shell_quote(root), shell_quote(
                "local h=dofile('test/support/harness.lua');h.install_loader();require('luainstaller.logger').logInfo('edge','parallel','" .. i .. "')"))
    end
    assert(command_ok(table.concat(workers, " ") .. " wait"))
    local script = "local h=dofile('test/support/harness.lua');h.install_loader();print(#require('luainstaller.logger').getLogs({descending=false}))"
    assert_equal(command_output("HOME=" .. shell_quote(root) .. " lua -e " .. shell_quote(script)):match("%d+"), "60", "log count")
    remove_tree(root)
end)
```

Inject a temporary-write failure after one valid entry and assert the previous
`logs.lua` remains loadable and unchanged.

- [ ] **Step 2: Verify concurrent count is below 60 on current read-modify-truncate code**

Run: `EDGE_FILTER=logger lua test/production_edges.lua`

Expected: retained count is less than 60.

- [ ] **Step 3: Implement lock ownership, stale recovery, atomic switch, and backup recovery**

```lua
local function withLock(callback)
    local lock, token = acquireLock(5, 120)
    if not lock then return false end
    local packed = table.pack(pcall(callback))
    local released = releaseOwnedLock(lock, token)
    if not packed[1] or not released then return false end
    return table.unpack(packed, 2, packed.n)
end
```

Perform load/append/trim/save and clear inside `withLock`. Write, flush, close,
and chmod a unique same-directory temp before switching. Retain a backup on
replace-limited platforms and recover it when the primary file is absent.

- [ ] **Step 4: Run concurrency repeatedly and logging contracts**

Run: `for i in 1 2 3; do EDGE_FILTER=logger lua test/production_edges.lua; done && lua test/contract_docs.lua`

Expected: every run retains exactly 60 entries and contracts pass.

- [ ] **Step 5: Commit logger transaction fixes**

```sh
git add src/logger.lua test/production_edges.lua test/contract_docs.lua
git commit -m "fix: serialize and atomically persist concurrent logs"
```

### Task 10: Installer and remote gate hardening

**Files:**
- Modify: `tools/install-source.sh`
- Modify: `tools/remote-test-linux.sh`
- Modify: `tools/remote-test-macos.sh`
- Modify: `tools/remote-test-windows.sh`
- Modify: `test/production_edges.lua`
- Modify: `test/smoke_all.lua`

**Interfaces:**
- Produces: source installer/wrappers that reject non-5.4 interpreters.
- Produces: shell helpers `require_safe_tmp_path`, `stage_source(name,url,sha256)`, and tracked-tree archive streaming.

- [ ] **Step 1: Add failing installer and remote-script static contracts**

```lua
test("source installer rejects LuaJIT before writing", function()
    if not command_ok("command -v luajit") then return end
    local root = make_temp_dir("old-lua-install")
    local ok = command_ok("sh tools/install-source.sh --lua luajit --prefix " .. shell_quote(root))
    assert(not ok)
    assert(not file_exists(root .. "/bin/luai"))
    remove_tree(root)
end)

test("remote scripts are pinned and non-destructive", function()
    for _, file in ipairs({ "tools/remote-test-linux.sh", "tools/remote-test-macos.sh", "tools/remote-test-windows.sh" }) do
        local text = read_file(file)
        assert(text:find("require_safe_tmp_path", 1, true), file)
        assert(text:find("sha256", 1, true), file)
        assert(text:find("git ls-files", 1, true), file)
        assert(not text:find("tar --exclude=.git", 1, true), file)
    end
    local windows = read_file("tools/remote-test-windows.sh")
    assert(not windows:find("StrictHostKeyChecking=no", 1, true))
end)
```

- [ ] **Step 2: Verify LuaJIT installation succeeds too far and insecure/archive assertions fail**

Run: `EDGE_FILTER=installer lua test/production_edges.lua && EDGE_FILTER='remote scripts' lua test/production_edges.lua`

Expected: both focused groups fail on current scripts.

- [ ] **Step 3: Implement exact ABI checks, safe roots, atomic pinned downloads, tracked archives, and strict SSH**

```sh
require_safe_tmp_path() {
    case "$1" in
        /tmp/luainstaller-*) ;;
        *) echo "unsafe temporary path: $1" >&2; exit 2 ;;
    esac
    case "$1" in *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
        echo "non-normalized temporary path: $1" >&2; exit 2;; esac
}

stage_source() {
    name=$1 url=$2 expected=$3
    destination=$SOURCE_CACHE/$name
    if [ -f "$destination" ] && ! printf '%s  %s\n' "$expected" "$destination" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$destination"
    fi
    if [ ! -f "$destination" ]; then
        part=$destination.part.$$
        trap 'rm -f "$part"' EXIT HUP INT TERM
        curl -fL --connect-timeout 20 --max-time 180 -o "$part" "$url"
        printf '%s  %s\n' "$expected" "$part" | sha256sum -c -
        mv "$part" "$destination"
        trap - EXIT HUP INT TERM
    fi
}
```

Use the four exact hashes from the design. Stream `git ls-files -z` through a
NUL-aware tar command. Pin cjson, LuaFileSystem, LuaSocket, Pegasus, and
mimetypes versions. Capture x64/mac smoke output and reject `skipped`. Run the
portable core suite on macOS. Default Windows SSH to strict known-host checking,
use direct key auth when no password exists, and wrap only password mode with
`sshpass -e`.

- [ ] **Step 4: Run shell syntax, static contracts, source installer, and local Wine gate**

Run: `for f in tools/*.sh; do sh -n "$f"; done && EDGE_FILTER=installer lua test/production_edges.lua && EDGE_FILTER='remote scripts' lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: all commands exit 0 with no insecure SSH assertion.

- [ ] **Step 5: Commit installer and remote hardening**

```sh
git add tools/install-source.sh tools/remote-test-linux.sh tools/remote-test-macos.sh \
  tools/remote-test-windows.sh test/production_edges.lua test/smoke_all.lua
git commit -m "fix: pin and guard installation test inputs"
```

### Task 11: Documentation, metadata, and portable test commands

**Files:**
- Modify: `README.adoc`
- Modify: `docs/BUNDLING.adoc`
- Modify: `docs/IMPLEMENTATION.adoc`
- Modify: `docs/PLATFORMS-NATIVE-LIMITS.adoc`
- Modify: `docs/TESTING.adoc`
- Modify: `docs/TROUBLESHOOTING.adoc`
- Modify: `docs/USAGE.adoc`
- Modify: `test/README.adoc`
- Modify: `test/runtime_bundle/main.lua`
- Modify: `luainstaller.1`
- Modify: `luainstaller-1.0.0-1.rockspec`
- Modify: `test/contract_docs.lua`
- Modify: `test/smoke_all.lua`

**Interfaces:**
- Documents: v2 migration, exact Lua ABI, entry-rooted search, runtime loader capture, SHA-256 ownership, same-environment fallback, safe remote variables, and all test gates.

- [ ] **Step 1: Add failing documentation contracts for every behavior change**

```lua
local implementation = read_file("docs/IMPLEMENTATION.adoc")
assert_contains(implementation, "luainstaller-generated-output-v2")
assert_contains(implementation, "SHA-256")
assert_contains(implementation, "loader data")
local usage = read_file("docs/USAGE.adoc")
assert_contains(usage, "Lua 5.4")
assert_contains(usage, "entry-rooted")
assert_contains(read_file("docs/TESTING.adoc"), "test/production_edges.lua")
```

- [ ] **Step 2: Verify documentation contracts fail on v1/FNV wording**

Run: `lua test/contract_docs.lua`

Expected: missing v2 or SHA-256 text assertion.

- [ ] **Step 3: Update documentation and make sample/test commands platform-portable**

Document the one-time v1 removal requirement, recursive refusal semantics,
actual runtime loader paths, supported path convention, exact ABI, marker and
manifest shapes, onefile deterministic cache behavior, strict remote host keys,
and checksum sources. Update runtime sample `package.path` setup so the documented
direct command works. Replace GNU-only documentation-contract listing commands
with Lua directory expectations or portable shell forms. Constrain the rockspec:

```lua
dependencies = {
    "lua >= 5.4, < 5.5",
}
```

- [ ] **Step 4: Run documentation, direct sample, manpage, and full suites**

Run: `lua test/runtime_bundle/main.lua docs && lua test/contract_docs.lua && lua test/cli_split_smoke.lua && lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: direct sample prints `hello docs`; all suites exit 0.

- [ ] **Step 5: Commit documentation and metadata**

```sh
git add README.adoc docs test/README.adoc test/runtime_bundle/main.lua \
  luainstaller.1 luainstaller-1.0.0-1.rockspec test/contract_docs.lua test/smoke_all.lua
git commit -m "docs: describe production safety and release gates"
```

### Task 12: Full verification, completion audit, and publication

**Files:**
- Review: every tracked change from `bbdec22` to branch HEAD
- Preserve: primary checkout `.review-patches/`

**Interfaces:**
- Produces: authoritative evidence for every design requirement and, only when complete, updated `origin/main`.

- [ ] **Step 1: Run local syntax and complete Lua suites from a clean worktree**

```sh
find src test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p
for script in tools/*.sh; do sh -n "$script"; done
lua test/cli_split_smoke.lua
lua test/contract_docs.lua
lua test/production_edges.lua
lua test/smoke_all.lua
git diff --check origin/main...HEAD
```

Expected: every command exits 0 and no edge test is filtered or skipped.

- [ ] **Step 2: Run compiler, sanitizer, install, and reproducibility gates**

Compile captured generated launcher/extractor sources with GCC and Clang C11
strict flags, run ASan/UBSan binaries, perform isolated `luarocks make`, source
install under a new prefix, clean-environment onedir/onefile execution, local
MinGW/Wine tests, logger concurrency repetition, and same-input binary compare.

Expected: zero warnings, sanitizer findings, missing modules, differing repeated
binaries, or retained partial outputs.

- [ ] **Step 3: Run required remote matrices**

```sh
sh tools/remote-test-linux.sh
sh tools/remote-test-macos.sh
sh tools/remote-test-windows.sh
```

Expected: Linux x64, Linux ARM64, macOS, Wine, and configured Windows targets all
report their explicit success markers and no `skipped` line. Any unreachable lab
or missing credential stops before publication.

- [ ] **Step 4: Audit requirements and final diff, then integrate locally**

Map every design paragraph to a test/output artifact, inspect `git diff
origin/main...HEAD`, confirm no secret, temp path, ignored artifact, debug output,
or `.review-patches/` entry is staged, then fast-forward local `main` to the
verified branch.

- [ ] **Step 5: Re-run post-integration smoke and push main without force**

```sh
git switch main
git merge --ff-only codex/production-hardening
lua test/production_edges.lua
lua test/smoke_all.lua
git push origin main
```

Expected: post-integration tests exit 0; push reports the verified commit range
on `main`; no tag is created or pushed.
