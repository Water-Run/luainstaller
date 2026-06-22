# Onefile Require Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cross-platform onefile packaging and selectable dependency discovery engines.

**Architecture:** Keep `src/bundler.lua` as the onedir implementation. Add `src/require_engine.lua` for static/manual/runtime dependency planning and `src/onefile.lua` for staging a normal onedir bundle, embedding it in a native extractor, and launching the extracted inner executable.

**Tech Stack:** Lua 5.4 project code, Lua C API launcher already present, portable C extractor generation, POSIX `cc`, MinGW for Windows profiles, existing smoke suite.

---

## File Map

- Create `src/require_engine.lua`: resolve dependency plans for `static`,
  `manual`, and `runtime`.
- Create `src/onefile.lua`: collect staged files, emit C extractor source, and
  compile it for Linux, macOS, or Windows.
- Modify `src/init.lua`: delegate dependency planning to `require_engine` and
  dispatch `mode = "onefile"` to `onefile.bundleOnefile`.
- Modify `src/cli.lua`: parse `--require-engine` and runtime args after `--`.
- Modify `src/cgen.lua`: preserve existing bootstrap behavior; no planned
  structural change unless tests expose an extraction path issue.
- Modify `luainstaller-1.0.0-1.rockspec`: install new modules.
- Modify `tools/install-source.sh`: copy new modules.
- Modify `test/smoke_all.lua`: add focused tests for all engines and onefile.
- Modify README/manpage docs after implementation behavior is verified.

## Tasks

### Task 1: Require Engine Module

- [ ] Add failing smoke coverage for manual and runtime engines in
  `test/smoke_all.lua`.
- [ ] Create `src/require_engine.lua` with `plan(opts)` returning
  `{ scripts = {}, libraries = {}, trace = {} }`.
- [ ] Move existing static/manual merge behavior from `src/init.lua` into the
  new module.
- [ ] Implement runtime tracing by running Lua with a temporary wrapper that
  records requested modules, then resolving those modules with
  `analyzer.ModuleResolver`.
- [ ] Wire `src/init.lua` to use `require_engine.plan`.
- [ ] Run `lua test/smoke_all.lua` and fix regressions.

### Task 2: CLI Require Engine Parsing

- [ ] Extend `src/cli.lua` to parse `--require-engine <static|manual|runtime>`.
- [ ] Preserve `--no-depscan` and `--manual` as aliases for
  `require_engine = "manual"`.
- [ ] Parse args after `--` into `opts.run_args`.
- [ ] Add smoke assertions that CLI runtime engine sees passed runtime args.
- [ ] Run `lua test/smoke_all.lua`.

### Task 3: Onefile Generator

- [ ] Add failing smoke coverage for a pure Lua onefile bundle.
- [ ] Create `src/onefile.lua` that stages an onedir bundle by calling
  `bundler.bundleOnedir`.
- [ ] Collect staged files recursively and compute relative paths, hashes,
  executable bits, and byte arrays.
- [ ] Generate a C extractor that writes files to a content-addressed temp
  directory, chmods executable files on POSIX, launches the inner executable,
  and returns its exit status.
- [ ] Compile the extractor using `cc` for Linux/macOS and MinGW for Windows.
- [ ] Wire `src/init.lua` so `mode = "onefile"` calls the onefile module instead
  of returning `NotImplementedError`.
- [ ] Run pure Lua onefile smoke.

### Task 4: Native Onefile Verification

- [ ] Extend smoke coverage to build and run one native local onefile sample.
- [ ] Ensure the extractor preserves nested `.luai/native` paths.
- [ ] Ensure the extracted inner launcher finds its copied Lua runtime and
  native modules.
- [ ] Run `lua test/smoke_all.lua`.

### Task 5: Packaging And Docs

- [ ] Add `luainstaller.require_engine` and `luainstaller.onefile` to the
  rockspec.
- [ ] Update `tools/install-source.sh` to copy the new modules.
- [ ] Update README, README-zh, and manpage option descriptions.
- [ ] Run `luac -p src/*.lua test/smoke_all.lua`.
- [ ] Run `sh -n tools/install-source.sh tools/remote-test-linux.sh
  tools/remote-test-macos.sh tools/remote-test-windows.sh`.
- [ ] Run `lua test/smoke_all.lua`.

## Self Review

The plan covers the approved spec: onefile staging and extractor generation,
three require engines, CLI/API wiring, packaging, and tests. There are no
placeholder tasks; each step names the file and expected behavior. The type
names are consistent: public option `require_engine`, runtime argument list
`run_args`, module entry point `require_engine.plan(opts)`, and onefile entry
point `onefile.bundleOnefile(opts)`.
