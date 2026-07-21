# Distribution Integrity and Release Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce path-clean, licensed, deterministic artifacts and make the full release matrix incapable of reporting a reduced or stale false green.

**Architecture:** Normalize generated metadata to logical paths, package required license/source notices, harden version caches and portable runners, and save machine-readable evidence from every local/remote/VM gate.

**Tech Stack:** Lua manifests/C generation, POSIX shell, PowerShell, Git/LuaRocks packaging, native platform runners.

## Global Constraints

- The mandatory matrix is Windows 11 x86_64, Debian 13 x86_64, Rocky Linux 10 x86_64, Ubuntu 24.04 ARM64, and macOS 26 ARM64.
- Windows 7, ReactOS, and old Linux are best-effort evidence, not 1.0 blockers.
- VM tests may be destructive; physical tests must not mutate system state or disturb existing workloads.
- Every pinned cache must prove exact patch version, archive digest, and LuaRocks version.
- All four required suites run without required skips.
- Same-content builds from different checkout roots must be byte-identical.
- Onedir and onefile must contain complete required notices and corresponding generated source.

---

### Task 1: Repair and strengthen the required smoke gate

**Files:**
- Modify: `test/smoke_all.lua:1140-1160`
- Modify: `docs/TESTING.adoc:1-20,140-155`
- Modify: `test/contract_docs.lua:500-530`

**Interfaces:**
- Produces: one authoritative release-contract phrase shared by tests and docs.

- [ ] **Step 1: Add a semantic assertion instead of stale prose matching**

Replace the literal `physical native hosts` assertion with checks for the
actual invariant:

```lua
assert_contains(testing, "native build and run on physical hosts")
assert_contains(testing, "not")
assert_contains(testing, "cross-compilers")
```

Update the document sentence to exactly:

```text
Release evidence is a native build and run on physical hosts; VMs, Wine,
MinGW, and cross-compilers are not substitutes for a mandatory physical class.
```

- [ ] **Step 2: Run the pre-change test and observe RED**

Run: `lua test/smoke_all.lua`

Expected: FAIL at the current `physical native hosts` literal assertion.

- [ ] **Step 3: Apply the semantic contract and run all four suites**

Run:

```bash
lua test/cli_split_smoke.lua
lua test/contract_docs.lua
LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua
lua test/smoke_all.lua
```

Expected: all four commands exit 0 and production edges prints its exact final
test count.

- [ ] **Step 4: Commit the release-contract repair**

```bash
git add test/smoke_all.lua test/contract_docs.lua docs/TESTING.adoc
git commit -m "test: align the release safety contract"
```

### Task 2: Logical paths and cross-root reproducibility

**Files:**
- Modify: `src/manifest.lua:104-159,243-268`
- Modify: `src/path.lua:71-110`
- Modify: `src/cgen.lua:181-243,338-357`
- Modify: `src/runtime.lua:124-133`
- Modify: `src/bundler.lua:1450-1620`
- Modify: `test/smoke_all.lua:1320-1390`
- Create: `test/reproducible_artifacts.lua`
- Modify: `docs/BUNDLING.adoc:45-105`

**Interfaces:**
- Produces: `path.relativeWithin(source_path, entry_root) -> safe relative path|nil`.
- Produces: `logicalSourcePath(entry_root, source_path) -> safe relative path`.
- Produces: manifest fields `source_id`, never build-host absolute paths.
- Produces: application `arg[0]` equal to the invoked executable path.

- [ ] **Step 1: Add cross-root and path-leak regressions**

Copy the same fixture into two roots with equal basenames, build onefile in
each, then assert:

```lua
assertEqual(sha256(first), sha256(second), "cross-root onefile hash")
for _, artifact in ipairs({ first, second }) do
    local strings = commandOutput("strings", { artifact })
    assert(not strings:find(first_root, 1, true))
    assert(not strings:find(second_root, 1, true))
    assert(not strings:find(os.getenv("USER") or "\0", 1, true))
end
```

Build an entry printing `arg[0]` and assert it reports the invoked onedir or
onefile executable, not the source script.

- [ ] **Step 2: Run and observe RED**

Run: `lua test/reproducible_artifacts.lua`

Expected: hashes differ, strings contain checkout paths, and `arg[0]` is the
original source path.

- [ ] **Step 3: Implement safe logical source IDs**

```lua
function M.relativeWithin(value, root)
    local absolute_value = path.normalize(path.absolute(value))
    local absolute_root = path.normalize(path.absolute(root))
    if absolute_value == absolute_root
        or not path.isWithin(absolute_value, absolute_root) then
        return nil
    end
    local relative = absolute_value:sub(#absolute_root + 2)
    return path.isSafeRelative(relative) and relative or nil
end

local function logicalSourcePath(entry_root, source_path)
    local relative = path.relativeWithin(source_path, entry_root)
    if not relative then
        return nil, result.error("UnsafeSourcePathError",
            "Source path cannot be represented in the bundle", {
                path = source_path,
            })
    end
    return relative:gsub("\\", "/")
end
```

Store `source_id` and destination/hash metadata in the generated manifest.
Keep absolute source paths only in the in-memory build result and logger, never
in generated C, manifest bytes, or payload metadata.

- [ ] **Step 4: Restore executable-style `arg[0]`**

Remove assignments that replace `arg[0]` with `entry.path`. Capture the actual
launcher path before executing bootstrap and retain it as `arg[0]`; expose the
logical entry ID in a private bootstrap variable used only for chunk names.

- [ ] **Step 5: Run reproducibility and smoke suites**

Run: `lua test/reproducible_artifacts.lua && lua test/smoke_all.lua && lua test/production_edges.lua`

Expected: byte-identical cross-root artifacts, no checkout/user strings, normal
`arg[0]`, and all existing manifest/runtime checks PASS after updating their
documented expectations.

- [ ] **Step 6: Commit deterministic metadata**

```bash
git add src/path.lua src/manifest.lua src/cgen.lua src/runtime.lua src/bundler.lua \
  test/smoke_all.lua test/reproducible_artifacts.lua docs/BUNDLING.adoc
git commit -m "fix: remove build paths from generated artifacts"
```

### Task 3: License and corresponding-source payload

**Files:**
- Create: `LICENSES/Lua-MIT.txt`
- Create: `LICENSES/GPL-3.0-or-later.txt`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `docs/RELINKING.adoc`
- Modify: `src/bundler.lua:430-480,1530-1620`
- Modify: `src/onefile.lua:172-247`
- Create: `test/distribution_licenses.lua`
- Modify: `README.adoc`
- Modify: `docs/BUNDLING.adoc`

**Interfaces:**
- Produces: `.luai/licenses/Lua-MIT.txt`,
  `.luai/licenses/LGPL-3.0-or-later.txt`,
  `.luai/licenses/GPL-3.0-or-later.txt`, `THIRD_PARTY_NOTICES.md`, generated
  launcher/extractor source, and relinking instructions in every distribution.

- [ ] **Step 1: Add RED distribution notice tests**

Build onedir and onefile, locate/extract their payloads, and assert:

```lua
assertContains(read(bundle .. "/.luai/licenses/Lua-MIT.txt"),
    "Permission is hereby granted, free of charge")
assertContains(read(bundle .. "/.luai/licenses/LGPL-3.0-or-later.txt"),
    "GNU LESSER GENERAL PUBLIC LICENSE")
assertContains(read(bundle .. "/.luai/licenses/GPL-3.0-or-later.txt"),
    "GNU GENERAL PUBLIC LICENSE")
assertContains(read(bundle .. "/THIRD_PARTY_NOTICES.md"), "Lua")
assert(fileExists(bundle .. "/.luai/build/launcher.c"))
assert(fileExists(bundle .. "/.luai/build/RELINKING.adoc"))
```

- [ ] **Step 2: Run and observe RED**

Run: `lua test/distribution_licenses.lua`

Expected: license/notice files are absent.

- [ ] **Step 3: Add authoritative license materials**

Copy the Lua license text from the official Lua source distribution already
verified by the version matrix. Copy the repository's `LICENSE` unchanged as
the LGPL payload text. Add the complete GPLv3 text published by GNU because the
LGPL file incorporates it by reference. Record source URLs, component version,
and copyright in `THIRD_PARTY_NOTICES.md`.

- [ ] **Step 4: Stage notices and corresponding source**

```lua
local distribution_files = {
    { source = "LICENSES/Lua-MIT.txt", destination = ".luai/licenses/Lua-MIT.txt" },
    { source = "LICENSE", destination = ".luai/licenses/LGPL-3.0-or-later.txt" },
    { source = "LICENSES/GPL-3.0-or-later.txt", destination = ".luai/licenses/GPL-3.0-or-later.txt" },
    { source = "THIRD_PARTY_NOTICES.md", destination = "THIRD_PARTY_NOTICES.md" },
    { source = "docs/RELINKING.adoc", destination = ".luai/build/RELINKING.adoc" },
}
```

Stage these through the same hash/manifest path as other generated files.
Ensure onefile `collectFiles` embeds them. Retain generated `launcher.c` and
`extractor.c` plus the exact compile command/relink instructions.

- [ ] **Step 5: Run notice, bundle, and onefile tests**

Run: `lua test/distribution_licenses.lua && lua test/native_bundle.lua && lua test/native_onefile.lua`

Expected: notices and corresponding source exist in both formats and artifact
execution remains unchanged.

- [ ] **Step 6: Commit distribution licensing**

```bash
git add LICENSES LICENSE THIRD_PARTY_NOTICES.md docs/RELINKING.adoc \
  README.adoc docs/BUNDLING.adoc src/bundler.lua src/onefile.lua \
  test/distribution_licenses.lua
git commit -m "docs: include distribution license notices"
```

### Task 4: Exact caches and portable matrix runners

**Files:**
- Modify: `tools/test-lua-versions.sh:45-180`
- Modify: `tools/test-lua-versions.ps1:120-260`
- Modify: `tools/remote-test-macos.sh:80-110,160-180,380-410`
- Modify: `test/version_contract.lua`
- Modify: `docs/TESTING.adoc:63-105`

**Interfaces:**
- Produces: POSIX `checksum(path, expected)` helper using `sha256sum` or
  `shasum -a 256`.
- Produces: exact cache marker with Lua patch, archive SHA-256, compiler tuple,
  and LuaRocks 3.13.0.
- Produces: full-suite execution for every pinned ABI.

- [ ] **Step 1: Add runner source-contract regressions**

Assert runners do not use bare `sha256sum`, `seq`, major/minor-only cache
checks, or existence-only LuaRocks checks. Assert every pinned version invokes
all four required suites.

- [ ] **Step 2: Run source contracts and observe RED**

Run: `lua test/version_contract.lua`

Expected: current GNU command, reduced suite, and weak cache patterns fail.

- [ ] **Step 3: Implement portable helpers**

```sh
checksum() {
    file=$1 expected=$2
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    fi
    test "$actual" = "$expected"
}

i=1
while [ "$i" -le 40 ]; do
    if ! kill -0 "$PID" >/dev/null 2>&1; then
        cat "$FIREBIRD_LOG"
        exit 1
    fi
    response=$(curl -fsS "http://127.0.0.1:$PORT/api/status" \
        -H "X-Auth-Token: $TOKEN" 2>/dev/null || true)
    if printf '%s\n' "$response" | grep '"ok":true' >/dev/null; then
        break
    fi
    sleep 0.25
    i=$((i + 1))
done
test "$i" -le 40
```

Validate exact Lua patch using the first line from `lua -v`, exact LuaRocks
using `luarocks --version`, and a marker containing the verified archive digest
and compiler identity. Delete/rebuild any mismatched cache.

- [ ] **Step 4: Run the full suite for every version**

Install the documented sample dependencies into each isolated LuaRocks tree,
then execute:

```sh
"$lua" test/cli_split_smoke.lua
"$lua" test/contract_docs.lua
LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 "$lua" test/production_edges.lua
"$lua" test/smoke_all.lua
```

Remove the `RUN_FULL_SUITE`/Lua-5.5-only branch.

- [ ] **Step 5: Run POSIX and macOS-local runner checks**

Run: `sh -n tools/*.sh && shellcheck tools/*.sh && lua test/version_contract.lua`

Expected: all exit 0 with no unexplained ShellCheck finding.

- [ ] **Step 6: Commit runner hardening**

```bash
git add tools/test-lua-versions.sh tools/test-lua-versions.ps1 \
  tools/remote-test-macos.sh test/version_contract.lua docs/TESTING.adoc
git commit -m "test: make release matrices exact and portable"
```

### Task 5: Evidence manifest and physical-host cleanup guard

**Files:**
- Create: `tools/release-evidence.sh`
- Create: `tools/release-evidence.ps1`
- Modify: `tools/remote-test-linux.sh`
- Modify: `tools/remote-test-macos.sh`
- Modify: `tools/remote-test-windows.sh`
- Modify: `docs/TESTING.adoc`
- Modify: `test/release_docs_contract.lua`

**Interfaces:**
- Produces: evidence directory containing `manifest.txt`, per-command logs,
  artifact hashes, dependency reports, process/listener before/after snapshots,
  and `cleanup.status`.
- Consumes: run-specific owner token and owned temporary root.

- [ ] **Step 1: Add evidence-contract assertions**

Require every remote runner to record `commit`, `host`, `os`, `arch`, `tools`,
`commands`, `artifacts`, `cleanup`, and `owner_token`, and to avoid `sudo`,
package-manager installs, system service changes, or fixed privileged ports.

- [ ] **Step 2: Run and observe RED**

Run: `lua test/release_docs_contract.lua`

Expected: current runners lack a uniform manifest and cleanup-status contract.

- [ ] **Step 3: Implement POSIX evidence helper**

```sh
record_command() {
    name=$1; shift
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    "$@" >"$EVIDENCE_DIR/$name.out" 2>"$EVIDENCE_DIR/$name.err"
    status=$?
    printf '%s\t%s\t%s\t%s\n' "$name" "$started" "$status" "$*" \
        >>"$EVIDENCE_DIR/commands.tsv"
    return "$status"
}
```

Record pre/post process and listener snapshots. Cleanup only paths containing
the current owner token, then verify their absence and write `cleanup.status=ok`.
PowerShell implements the same field names and semantics.

- [ ] **Step 4: Integrate all remote runners**

Create a unique non-symlink temporary root, check disk/memory/load headroom,
choose free nonprivileged ports, source the evidence helper, copy evidence back,
and verify cleanup. Do not mutate physical machine system state.

- [ ] **Step 5: Run contract/static checks and commit**

Run: `lua test/release_docs_contract.lua && sh -n tools/*.sh && shellcheck tools/*.sh`

Expected: all PASS.

```bash
git add tools/release-evidence.sh tools/release-evidence.ps1 \
  tools/remote-test-linux.sh tools/remote-test-macos.sh \
  tools/remote-test-windows.sh docs/TESTING.adoc test/release_docs_contract.lua
git commit -m "test: preserve release evidence safely"
```

### Task 6: Temporary-tag LuaRocks packaging preflight

**Files:**
- Create: `tools/release-pack-preflight.sh`
- Modify: `docs/TESTING.adoc`
- Modify: `test/release_docs_contract.lua`

**Interfaces:**
- Produces: a `.src.rock`, isolated install log, and checksum from a temporary
  immutable local tag without creating or pushing the real release tag.

- [ ] **Step 1: Add release preflight contract**

Assert the testing document runs packaging preflight after all tests and states
that the real `v1.0.0` tag is created only after mandatory evidence is green.

- [ ] **Step 2: Implement the temporary mirror preflight**

```sh
mirror=$(mktemp -d "${TMPDIR:-/tmp}/luainstaller-pack.XXXXXX")
git clone --bare . "$mirror/repo.git"
git --git-dir="$mirror/repo.git" tag -f v1.0.0 HEAD
sed "s#git+https://github.com/Water-Run/luainstaller.git#git+file://$mirror/repo.git#" \
  luainstaller-1.0.0-1.rockspec >"$mirror/luainstaller-1.0.0-1.rockspec"
(cd "$mirror" && luarocks pack luainstaller-1.0.0-1.rockspec)
luarocks install --tree "$mirror/tree" "$mirror"/luainstaller-1.0.0-1.src.rock
"$mirror/tree/bin/luai" -v
```

Use a trap/owner token to remove the mirror. Confirm the committed rockspec was
not modified and no real tag was created.

- [ ] **Step 3: Run packaging preflight**

Run: `sh tools/release-pack-preflight.sh`

Expected: source rock created, isolated install exits 0, installed CLI reports
1.0.0, temporary mirror removed, and `git tag --list v1.0.0` remains empty.

- [ ] **Step 4: Commit packaging preflight**

```bash
git add tools/release-pack-preflight.sh docs/TESTING.adoc \
  test/release_docs_contract.lua
git commit -m "test: verify release packaging before tagging"
```

### Task 7: Execute mandatory physical and destructive VM matrices

**Files:**
- Evidence only: owned local evidence directory outside the tracked tree.
- Modify only if a test exposes a new product or runner defect.

**Interfaces:**
- Consumes: all preceding test runners and evidence helpers.
- Produces: one complete evidence manifest per mandatory platform and one
  best-effort report per old VM platform.

- [ ] **Step 1: Run fresh local static and full Lua matrix gates**

Run all four suites, exact five-version matrices, generated-C analyzers,
ShellCheck, rockspec lint/install, packaging preflight, diff check, and secret
scan. Save every command and hash.

- [ ] **Step 2: Run mandatory physical Linux/macOS classes cautiously**

Use owned temporary roots on Rocky 10 x86_64, Debian 13 x86_64, Ubuntu 24
ARM64, and macOS 26 ARM64. Verify resource headroom first; do not install system
packages or change services. Copy evidence back, cleanup, and compare pre/post
process/listener snapshots.

- [ ] **Step 3: Build or reset a Windows 11 x86_64 clean VM**

Snapshot before testing. Remove/avoid Lua, LuaRocks, Visual Studio, and VC
Redistributable in the clean-target snapshot. Run the complete native
PowerShell matrix and dependency/lifecycle tests. Revert or retain a labeled
post-test snapshot.

- [ ] **Step 4: Run best-effort destructive old-platform VM tests**

Exercise Windows 7, ReactOS, and available old Linux with install, clean-target,
corruption, signal, low-disk, permission, and recovery cases. Record failures
without weakening mandatory criteria.

- [ ] **Step 5: Audit cleanup and release claims**

Verify no owned temp root, orphan process, listener, lock, staging path, or VM
test process remains. Map every completion criterion in the design spec to a
specific log/manifest line. Any missing or failed mandatory item leaves status
NO-GO and triggers another TDD repair cycle.
