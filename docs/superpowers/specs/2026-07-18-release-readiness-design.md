# Release-readiness remediation design

Date: 2026-07-18
Status: approved for autonomous implementation

## Context

The release review of commit `68837fa17a566dd9cb74d49c2bba71f711b70959`
showed that the ordinary CLI, clean-target onedir/onefile execution, and the
pinned Lua 5.1-5.5 matrix are broadly healthy. It also reproduced correctness
and lifecycle defects that make the current tree a release NO-GO:

- the required `smoke_all` suite is stale relative to the release document;
- runtime discovery chooses the wrong interpreter through a LuaRocks wrapper
  and accepts a tracer from the wrong Lua ABI;
- the analyzer uses one builtin-module set for every Lua ABI;
- Linux accepts static liblua even though the documented profile requires a
  shared runtime, producing launchers that cannot load ordinary C modules;
- custom shared prefixes are probed with one environment and inspected with
  another;
- interruption can leave a permanent output lock and staging directory;
- onefile does not preserve process-lifecycle semantics for long-running
  applications;
- generated artifacts do not carry complete Lua/project license notices;
- release runners have cache, platform, and clean-target coverage gaps.

The user approved a contract-first targeted remediation and requested that the
remaining work and tests run autonomously.

## Release scope

The mandatory 1.0 platform classes remain the public matrix:

- Windows 11 x86_64;
- Debian 13 x86_64;
- Rocky Linux 10 x86_64;
- Ubuntu 24.04 ARM64;
- macOS 26 ARM64.

Windows 7, ReactOS, and older Linux distributions receive best-effort
compatibility testing. A failure there is recorded with evidence but is not a
1.0 release blocker unless the same defect affects the public matrix.

The implementation remains native-only. It does not add cross-compilation,
universal macOS binaries, Wine/MinGW support, or recursive closure of arbitrary
third-party native-library dependencies.

## Safety policy for test environments

Virtual machines may be created, snapshotted, reverted, reinstalled, or used
for destructive fault-injection tests. A test must still record the original
VM power/snapshot state and leave a useful final state.

Physical machines are treated as shared systems:

- use an owned temporary root or the test user's home directory;
- do not use `sudo`, install system packages, change services, firewall, login
  configuration, global compiler settings, or persistent shell profiles;
- use non-privileged dynamically selected ports and check for conflicts first;
- place process groups, PIDs, logs, and test roots under the run manifest;
- terminate only processes whose owner token belongs to the current run;
- verify removal of temporary roots and absence of orphan listeners/processes;
- preserve existing workloads and abort a stress case when resource headroom is
  insufficient.

## Chosen approach

Use targeted modules and validation boundaries rather than rewriting the
application or removing advertised features. Every reproduced defect first
gets a failing regression test. The production change must be the smallest
change that makes that test and the existing contract pass.

Alternatives rejected:

- a platform-layer rewrite has a larger 1.0 regression surface;
- deleting runtime discovery, onefile lifecycle support, or native-module
  support would make the test suite green by shrinking the product contract.

## ABI and discovery design

Introduce `src/lua_abi.lua` as the single internal ABI-capability source. It
owns:

- the normalized ABI (`5.1` through `5.5`);
- builtin Lua modules for that ABI;
- syntax/runtime features relevant to discovery;
- exact equality checks for analyzer, tracer, headers, linked runtime, and
  bundled native modules.

Expected builtin differences include:

- `utf8` is not builtin on 5.1 or 5.2;
- `bit32` is builtin on the official 5.2 and 5.3 builds but not 5.1, 5.4, or
  5.5.

Runtime discovery validates the candidate interpreter before executing user
code. Explicit `--lua` and `LUAI_LUA` remain authoritative but must report an
ABI mismatch before tracing. Default discovery scans the actual negative
argument vector used by Lua/LuaRocks, accepting only an executable candidate
that successfully identifies itself as an official interpreter of the active
ABI. Bootstrap source strings and wrapper script paths cannot be accepted as
interpreters. If no candidate can be proven, the command returns a structured
`ToolchainError` that requests `--lua`; it never silently changes ABI.

The selected and verified interpreter identity is reused for the complete
trace. The manifest records that identity and its ABI so later phases cannot
substitute another runtime.

## Native toolchain design

Toolchain candidates are constrained by the selected platform profile before
compile probing:

- Linux requires a matching shared liblua. Static `.a` candidates are rejected
  with a diagnostic that matches the public contract.
- macOS requires matching static `liblua.a`; `.dylib` and `.so` candidates are
  rejected rather than copied without install-name rewriting.
- Windows 1.0 is explicitly x86_64. x86 and ARM64 hosts receive an
  `UnsupportedPlatformError` instead of being routed into x64 MSVC paths.

Explicit prefixes support ordinary `lib` and `lib64` layouts, safe symlinks,
and versioned shared libraries where the loader identity can be proven. All
subprocesses involved in compile, execution, `ldd`/`otool` inspection, and
staged verification receive the same explicitly constructed environment.

Verification occurs against staged distribution files rather than only the
source prefix:

1. compile and run the matching-runtime probe;
2. copy the runtime into the private staging layout;
3. compile a minimal ordinary Lua C module with unresolved Lua API references;
4. launch the staged executable in a clean environment with the source prefix
   hidden;
5. require the C module and verify its result;
6. inspect loader dependencies and reject unresolved or source-prefix paths;
7. only then publish the artifact.

Windows release builds compile the generated launchers, extractor, and the
matrix-built Lua DLL with `/MT`, so their C runtime is part of each binary.
The release runner inspects PE dependencies and tests in a VM without a
preinstalled VC Redistributable; any unexpected VCRuntime/UCRT dependency is a
release failure.

## Transaction and interruption design

An onedir/onefile build is one transaction:

`validate -> acquire output lock -> create staging -> build -> verify ->
atomic publish -> cleanup`.

A common protected-call/finalizer boundary owns the output lock and all staging
paths. Every normal error and Lua-level interruption runs the finalizer. The
lock record contains PID, creation time, and a random owner token. Cleanup
removes a lock only when the token still matches. Stale recovery removes a
lock only after proving the owner process no longer exists and proving the
record was not replaced after observation. This also recovers from SIGKILL,
power loss, or interpreter crashes that cannot run a finalizer.

Expected interruption is normalized to a structured `InterruptedError` and an
appropriate CLI status without an internal traceback. Permission failures
preserve their actual cause and never masquerade as lock contention.

If cleanup fails after atomic publication, the valid artifact remains and the
result explicitly reports `committed=true` and the cleanup path. A failure
before publication guarantees that the requested output path was not created.

## Onefile process-lifecycle design

On POSIX, after successful cache extraction and validation, the outer onefile
process uses `execv` for the inner launcher. The application therefore retains
the original PID and naturally receives signals, job-control events, and exit
status.

On Windows, the outer process creates a Job Object, assigns the child before
letting it execute, and sets `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Console
control events continue through the shared console, and forced outer-process
termination closes the job and terminates the child. Setup failures terminate
the suspended child and close all handles before returning.

Regression tests cover short programs, long-running HTTP programs, normal
exit, nonzero exit, SIGINT/TERM on POSIX, forced outer termination, and the
Windows Job Object path.

## Reproducibility and runtime identity

Build-machine absolute paths and user names must not be embedded in release
artifacts. Manifests store stable logical source identifiers relative to the
entry root. Diagnostics may retain absolute paths only outside generated
artifacts. Generated bootstrap code uses logical identifiers for chunk names.

Application `arg[0]` becomes the invoked artifact path, matching normal
executable behavior. The original logical entry path, if needed for diagnostics,
is exposed separately rather than masquerading as the executable path.

Acceptance requires byte-identical onefile output from two checkout roots with
identical contents, in addition to same-root repeated-build determinism.

## Licensing design

The repository and generated distributions carry explicit notices for every
component copied or embedded by luainstaller:

- the complete Lua MIT license and copyright notice;
- the project's LGPL-3.0-or-later text;
- the corresponding GNU GPL text referenced by LGPL;
- a third-party notice identifying the bundled Lua version and source;
- generated launcher/extractor corresponding source and reproducible relink
  instructions appropriate to the existing project license.

Onedir places these files in a stable `LICENSES`/notice location. Onefile embeds
the same files in its payload so the extracted distribution contains them.
Tests inspect both formats for exact required notices. This design does not
claim to audit application-supplied native modules; their licensing remains the
application distributor's responsibility and is documented separately.

## Test design

### Focused red tests

Add isolated regressions for every confirmed defect:

- stale release-document assertion;
- LuaRocks wrapper interpreter selection;
- explicit tracer ABI mismatch;
- per-ABI `utf8` and `bit32` behavior on all five official interpreters;
- Linux static-lib rejection and shared-lib C-module success;
- custom-prefix loader environment and `lib64`/symlink layouts;
- interrupted-build finalization and stale recovery;
- onefile signal/child lifecycle;
- license presence;
- cross-checkout reproducibility and `arg[0]` semantics;
- Windows architecture rejection and clean CRT closure;
- exact patch-version/source-cache verification.

Each test is observed failing against the pre-fix behavior before production
code changes, then passing after the fix.

### Local release gate

The mandatory local gate is:

1. all production Lua files parse under each pinned interpreter;
2. `cli_split_smoke`, `contract_docs`, `production_edges`, and `smoke_all` all
   pass without required skips;
3. full edge prerequisites are required, not optional;
4. rockspec lint and isolated LuaRocks install pass;
5. generated C passes strict warnings and available static analyzers;
6. shell scripts pass syntax and ShellCheck without unexplained findings;
7. Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8, and 5.5.0 each run the complete relevant
   suite, not a reduced default subset;
8. `git diff --check`, clean-tree review, credential scan, and release metadata
   checks pass.

Pinned caches validate exact patch version, archive digest, build metadata, and
LuaRocks version before reuse. macOS scripts use portable checksum and sequence
helpers available on a stock host.

### Clean-target and fault matrix

Every mandatory platform class proves:

- onedir and onefile work with no `lua`, `luajit`, or `luarocks` in PATH and
  with Lua environment variables cleared;
- a real native C module loads from the bundle;
- a custom prefix remains relocatable after the source prefix is hidden;
- spaces, Unicode, quotes, long paths, symlink/PATH invocation, read-only input,
  and non-writable/noexec temporary locations behave as specified;
- repeated and concurrent builds preserve atomicity and ownership;
- cache corruption is repaired without accepting tampered payloads;
- SIGINT/TERM, parent death, child failure, and stale locks leave no orphan
  process, listener, lock, or staging path;
- same-root and cross-root reproducibility checks pass;
- license and notice files are present;
- dependency inspection has no unexpected build-host path or unresolved runtime.

### Environment execution

Run the complete five-version matrix and clean-target cases on all reachable
mandatory physical classes, following the physical-machine safety policy.
Use VMs freely for Windows clean-room, old Linux, ReactOS, corruption,
interruption, low-disk, noexec, permission, and destructive recovery cases.

If a mandatory platform is not reachable, release readiness remains unproven;
the result cannot be promoted from release candidate to ready. Best-effort old
platform failures are recorded separately and do not lower the mandatory
matrix.

## Release evidence and metadata

Every run writes a manifest containing commit, host identity, OS/architecture,
tool versions, exact commands, exit status, checksums, temporary roots, and
cleanup result. Evidence is copied back before remote cleanup.

The rockspec release tag is a final publication step, not created merely to
make tests pass. Before publication, a temporary immutable source mirror/tag is
used to prove `luarocks pack` and isolated source installation. The real
`v1.0.0` tag is created and pushed only after every mandatory gate is green.

Release documentation must distinguish mandatory support, best-effort evidence,
and out-of-scope platforms. CI/manual runner instructions must reproduce the
same full gates rather than a reduced green subset.

## Completion criteria

The tree is release-ready only when all of the following are true:

- every confirmed blocker has a regression test and verified fix;
- all four required suites and rockspec lint pass;
- every pinned Lua version passes the full local and platform-relevant gates;
- every reachable mandatory platform passes native build and true clean-target
  execution, with no mandatory platform result represented by a skip;
- Windows clean-room evidence proves dependency closure;
- no orphan process, listener, lock, staging directory, or remote test root
  remains;
- generated artifacts contain the required notices and no build-user/path
  leakage;
- release metadata and temporary-tag packaging checks pass;
- the final worktree receives a fresh diff/static/test audit and the saved
  evidence supports every release claim.

Until every criterion has direct evidence, the release status remains NO-GO.
