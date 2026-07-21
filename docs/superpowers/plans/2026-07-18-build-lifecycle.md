# Build Transaction and Onefile Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure interruption, crashes, and outer-process termination never leave permanent build state or orphan onefile applications.

**Architecture:** Put output locks and staging paths under one ownership-aware transaction finalizer. Replace POSIX onefile fork/wait with exec and use a kill-on-close Windows Job Object for the extracted child.

**Tech Stack:** Portable Lua protected calls, POSIX process primitives, Win32 Job Objects, existing fs/process/result helpers.

## Global Constraints

- Preserve atomic publication and never delete another build's lock or files.
- Normal errors and SIGINT-visible Lua errors must clean owned lock/staging state.
- SIGKILL/crash recovery must require a dead owner and unchanged owner token.
- POSIX onefile must preserve PID, signal, and exit semantics.
- Windows onefile must terminate the child when the outer process dies.
- Expected failures use structured errors without internal tracebacks.

---

### Task 1: Ownership-aware build transaction

**Files:**
- Modify: `src/bundler.lua:1360-1635`
- Modify: `src/result.lua:1-180`
- Modify: `test/production_edges.lua:2500-2750`

**Interfaces:**
- Produces: internal `withBuildTransaction(out_path, callback)`.
- Produces: transaction methods `stagePath(path)`, `commit()`, and `finish(result)`.
- Consumes: existing output lock acquire/release and staging cleanup helpers.

- [ ] **Step 1: Add finalizer injection tests**

Inject an error after lock acquisition, after staging creation, during compile,
and immediately before publish. For each point assert:

```lua
assert(result.ok == false)
assert(not pathExists(output_path))
assert(not pathExists(expected_lock))
assert(#findMatching(parent, ".luai-staging-") == 0)
```

Add a post-publish cleanup injection and assert the artifact remains valid,
`result.error.committed == true`, and `result.error.output_path == output_path`.

- [ ] **Step 2: Run the injection tests and observe RED**

Run: `LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua`

Expected: at least the compile interruption path leaves an owned lock and
staging directory.

- [ ] **Step 3: Implement the transaction finalizer**

```lua
local function withBuildTransaction(out_path, callback)
    local transaction, begin_err = beginOutputTransaction(out_path)
    if not transaction then return begin_err end

    local called, value = xpcall(function()
        return callback(transaction)
    end, function(failure)
        return failure
    end)

    local primary = called and value or makeError(
        "BuildFailedError", "Build transaction was interrupted", {
            cause = tostring(value),
        })
    return transaction:finish(primary)
end
```

`finish` removes every registered staging path in reverse order, then releases
only the matching owner-token lock. It attaches cleanup errors to the primary
structured error. If `commit()` was called, it preserves the output and sets
`committed=true`.

- [ ] **Step 4: Route onedir through the transaction**

Replace manual acquire/stage/abandon/release branches with one callback. Every
new staging path is registered before the first operation that can fail.

- [ ] **Step 5: Run production edges and smoke tests**

Run: `LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua && lua test/smoke_all.lua`

Expected: all tests PASS and failure-injection leaves no lock/staging entries.

- [ ] **Step 6: Commit transaction finalization**

```bash
git add src/bundler.lua src/result.lua test/production_edges.lua
git commit -m "fix: finalize interrupted build transactions"
```

### Task 2: Safe stale-lock recovery

**Files:**
- Create: `src/lock_owner.lua`
- Modify: `src/bundler.lua:1250-1430`
- Modify: `src/logger.lua:150-390`
- Modify: `src/cli.lua:55-115`
- Modify: `test/support/harness.lua:43-65`
- Modify: `luainstaller-1.0.0-1.rockspec:43-67`
- Modify: `test/production_edges.lua:1800-2150`

**Interfaces:**
- Produces: lock record `{token, pid, created}`.
- Produces: compare-before-delete recovery for dead owners.
- Produces: `lock_owner.isAlive(pid) -> boolean|nil, reason`.
- Reuses: logger's owner-token and replace-after-observation protections.

- [ ] **Step 1: Add stale and ABA regressions**

Cover a dead PID lock, live PID lock, malformed lock, empty pre-publication
lock, and a lock replaced between observation and removal. Assert only the
dead unchanged owner is recovered.

- [ ] **Step 2: Run stale recovery tests and observe RED**

Run: `lua test/production_edges.lua`

Expected: build locks have no dead-owner recovery and the retry still reports
`Another build is using this output path`.

- [ ] **Step 3: Share an owner record codec**

```lua
local function encodeOwner(owner)
    return table.concat({
        "token=" .. owner.token,
        "pid=" .. tostring(owner.pid),
        "created=" .. tostring(owner.created),
        "",
    }, "\n")
end

local function sameOwner(before, after)
    return before.token == after.token
        and before.pid == after.pid
        and before.created == after.created
end

local function isAlive(pid)
    if package.config:sub(1, 1) == "\\" then
        local script = table.concat({
            "$p=Get-Process -Id ", tostring(pid), " -ErrorAction SilentlyContinue;",
            "if($null -eq $p){exit 1}",
        })
        local ok = process.outputPowerShell(script)
        return ok and true or false
    end
    local ok = process.outputCommand("kill", { "-0", tostring(pid) })
    return ok and true or false
end
```

Put the codec, token generation, process-liveness probe, and compare operation
in `src/lock_owner.lua`. Add it to the CLI checkout loader, test harness, and
rockspec. Both logger and bundler consume that module, avoiding a dependency
between the two lock users.

- [ ] **Step 4: Implement compare-before-delete recovery**

Read the record, prove the PID dead, read it again, compare all fields, then
remove through a rename-to-private-owner path. If any check changes, leave the
lock untouched.

- [ ] **Step 5: Re-run stale/ABA and concurrency tests**

Run: `LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 lua test/production_edges.lua`

Expected: dead lock retry succeeds; live, malformed, and replaced locks remain;
all existing logger ABA tests still PASS.

- [ ] **Step 6: Commit stale recovery**

```bash
git add src/lock_owner.lua src/bundler.lua src/logger.lua src/cli.lua \
  test/support/harness.lua test/production_edges.lua \
  luainstaller-1.0.0-1.rockspec
git commit -m "fix: recover abandoned output locks safely"
```

### Task 3: End-to-end SIGINT cleanup

**Files:**
- Create: `test/build_interruption.lua`
- Modify: `src/cli.lua:760-850`
- Modify: `src/process.lua:175-215`
- Modify: `tools/test-lua-versions.sh:147-177`
- Modify: `tools/test-lua-versions.ps1:215-230`

**Interfaces:**
- Produces: `InterruptedError` result and CLI status 130 for SIGINT-visible
  interruption.
- Consumes: transaction finalizer from Task 1.

- [ ] **Step 1: Write the slow-compiler integration test**

The POSIX test launches a build with a compiler wrapper that delays only the
generated launcher compile, sends SIGINT, waits for exit, and checks:

```lua
assertEqual(exit_status, 130, "SIGINT status")
assert(not outputContains(stderr, "stack traceback"))
assert(not fileExists(lock_path))
assert(#stagingPaths(parent) == 0)
assert(runNormalRetry(output_path) == 0)
```

This integration test is POSIX-only. The Windows VM fault test in Task 5
terminates the parent forcefully and verifies dead-owner stale recovery.

- [ ] **Step 2: Run the interruption test and observe RED**

Run: `lua test/build_interruption.lua`

Expected: exit 124/1, traceback output, remaining lock/staging, and failed retry.

- [ ] **Step 3: Normalize interruption at the CLI boundary**

```lua
local called, response = xpcall(runCommand, function(value)
    local message = tostring(value)
    if message:find("interrupted!", 1, true) then
        return result.error("InterruptedError", "Build interrupted", {})
    end
    return result.error("InternalError", "Unhandled build failure", {
        cause = message,
    })
end)
```

Map `InterruptedError` to status 130 and do not render a traceback. Preserve
the transaction's structured cleanup detail.

- [ ] **Step 4: Run interruption and normal build tests**

Run: `lua test/build_interruption.lua && lua test/cli_split_smoke.lua && lua test/smoke_all.lua`

Expected: all PASS; retry builds and runs the artifact.

- [ ] **Step 5: Add the integration test to matrix runners and commit**

```bash
git add test/build_interruption.lua src/cli.lua src/process.lua \
  tools/test-lua-versions.sh tools/test-lua-versions.ps1
git commit -m "fix: cleanly interrupt native builds"
```

### Task 4: POSIX onefile exec semantics

**Files:**
- Modify: `src/onefile.lua:1193-1245`
- Create: `test/onefile_lifecycle.lua`
- Modify: `tools/test-lua-versions.sh:147-177`

**Interfaces:**
- Produces: generated POSIX extractor whose final operation is
  `execv(exe_path, child_argv)`.
- Produces: application PID equal to invoked onefile PID.

- [ ] **Step 1: Add long-running process regressions**

Build a onefile HTTP fixture on a free nonprivileged port. Assert its reported
PID equals the launched PID, send SIGTERM, and assert the port closes and no
matching child remains. Repeat with SIGINT and a short program returning 23.

- [ ] **Step 2: Run and observe RED**

Run: `lua test/onefile_lifecycle.lua`

Expected: reported PID differs and the inner service remains after terminating
the outer process.

- [ ] **Step 3: Replace fork/wait with exec**

```c
static int luai_run_inner(const char *exe_path, int argc, char **argv) {
    char **child_argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
    int i;
    if (!child_argv) return 1;
    child_argv[0] = (char *)exe_path;
    for (i = 1; i < argc; ++i) child_argv[i] = argv[i];
    child_argv[argc] = NULL;
    execv(exe_path, child_argv);
    perror("luainstaller-onefile: execv");
    free(child_argv);
    return 127;
}
```

- [ ] **Step 4: Run lifecycle, cache, and onefile suites**

Run: `lua test/onefile_lifecycle.lua && lua test/native_onefile.lua && lua test/smoke_all.lua`

Expected: PID/signal/exit assertions PASS and existing cache behavior remains.

- [ ] **Step 5: Commit POSIX lifecycle behavior**

```bash
git add src/onefile.lua test/onefile_lifecycle.lua tools/test-lua-versions.sh
git commit -m "fix: preserve POSIX onefile process semantics"
```

### Task 5: Windows Job Object lifecycle

**Files:**
- Modify: `src/onefile.lua:1156-1191`
- Modify: `test/onefile_lifecycle.lua`
- Modify: `tools/test-lua-versions.ps1:215-230`

**Interfaces:**
- Produces: generated Windows extractor using a suspended child assigned to a
  kill-on-close Job Object before resume.

- [ ] **Step 1: Add generated-source and VM regressions**

Assert generated source contains `CreateJobObjectA`,
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, `AssignProcessToJobObject`, and
`CREATE_SUSPENDED`. In Windows VM, terminate the outer PID and assert the inner
PID exits and its port closes.

- [ ] **Step 2: Run source regression and observe RED**

Run: `lua test/production_edges.lua`

Expected: generated source has only `CreateProcessA(..., 0, ...)` and fails the
new Job Object assertions.

- [ ] **Step 3: Implement Job Object setup**

```c
job = CreateJobObjectA(NULL, NULL);
info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
SetInformationJobObject(job, JobObjectExtendedLimitInformation,
    &info, sizeof(info));
CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_SUSPENDED,
    NULL, NULL, &si, &pi);
AssignProcessToJobObject(job, pi.hProcess);
ResumeThread(pi.hThread);
```

Every failure path terminates a created suspended child, waits for it, and
closes thread/process/job handles. Normal completion returns the child status.

- [ ] **Step 4: Run native Windows lifecycle matrix**

Run on Windows 11 VM:
`powershell -NoProfile -File tools/test-lua-versions.ps1 -HostLabel windows-job`

Expected: five PASS lines and no child/listener after each forced outer exit.

- [ ] **Step 5: Commit Windows lifecycle behavior**

```bash
git add src/onefile.lua test/onefile_lifecycle.lua \
  test/production_edges.lua tools/test-lua-versions.ps1
git commit -m "fix: contain Windows onefile child processes"
```
