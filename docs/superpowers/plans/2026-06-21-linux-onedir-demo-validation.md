# Linux Onedir Demo Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement and verify Linux `--onedir` packaging for pure Lua and native Lua C module examples in the repository's `test/` demo set.

**Architecture:** Add `src/bundler.lua` as the filesystem/toolchain layer that consumes analyzer output and manifest data, generates a C launcher through `luainstaller.launcher`, compiles it with the local Linux Lua toolchain, writes `.luai/manifest.lua`, and copies the linked Lua shared runtime plus native modules into `.luai/native/`. Extend `cgen` only where needed to preserve real module names and prepend runtime native search paths.

**Tech Stack:** Lua 5.4-compatible project code, Linux `cc`, `pkg-config lua`, Lua C API, LuaRocks native modules such as `cjson` and `lsqlite3`, smoke tests in `test/smoke_all.lua`.

---

## File Map

- Modify `test/smoke_all.lua`: add failing onedir bundle tests for pure Lua, `cjson`, and `lsqlite3` samples, plus launcher runtime-library checks.
- Modify `src/cgen.lua`: accept explicit `module_names` and `native_dir` options for generated bootstrap behavior.
- Create/modify `src/bundler.lua`: implement Linux onedir creation, manifest writing, native copies, C generation, and compilation.
- Modify `src/init.lua`: call `luainstaller.bundler` for `mode = "onedir"` and preserve `NotImplementedError` for `onefile`.
- Modify `src/cli.lua`: render successful bundle output.
- Modify `luainstaller-1.0.0-1.rockspec`: install `luainstaller.bundler`.
- Modify README files and roadmap/manpage after behavior is verified.

## Task 1: Onedir Smoke Coverage

- [x] Add a helper in `test/smoke_all.lua` that removes and recreates temporary bundle directories under `/tmp`.
- [x] Add a test that calls `luainstaller.bundle()` for `test/runtime_bundle/main.lua`, runs the generated executable, and expects `hello onedir`.
- [x] Add a test that packages `test/student_management_system/main.lua`, runs command mode from the bundle, and expects seeded student output using bundled `cjson`.
- [x] Add a test that packages `test/savinglua/main.lua`, runs `put` and `get` with a temporary SQLite database, and expects stored JSON output using bundled `lsqlite3`.
- [x] Run `lua test/smoke_all.lua` and confirm the new checks fail because `bundle()` still returns `NotImplementedError`.

## Task 2: Cgen Runtime Support

- [x] Add a `native_dir` option to `cgen.generateBootstrap()` and generated runtime code.
- [x] Prepend `<native_dir>/?.so` and `<native_dir>/?/init.so` to `package.cpath` before installing the bundled Lua searcher.
- [x] Use trace-derived `module_names[path]` when building payloads so `savinglua.store` maps to the correct embedded module.
- [x] Run the targeted runtime/cgen smoke checks and keep existing generated-bootstrap behavior passing.

## Task 3: Bundler Implementation

- [x] Implement `src/bundler.lua` with structured result helpers and filesystem helpers.
- [x] Build module name mappings from trace records where `classification == "lua"` and `selected_path` is present.
- [x] Create the output layout: executable path plus `.luai/native/` and `.luai/manifest.lua`.
- [x] Generate C source through `launcher.generateSource()` with `native_dir = ".luai/native"`.
- [x] Compile with `cc <generated.c> -o <exe> $(pkg-config --cflags --libs lua)`.
- [x] Link the launcher with `$ORIGIN/.luai/native` as runtime library search path.
- [x] Copy the linked Lua shared runtime into `.luai/native/` and record it in the manifest.
- [x] Copy native modules listed in the manifest into `.luai/native/`.
- [x] Return `{ ok = true, action = "bundle", mode = "onedir", executable = ... }`.

## Task 4: Public API And CLI Wiring

- [x] Register `luainstaller.bundler` in source preloads and the rockspec.
- [x] Update `luainstaller.bundle(opts)` to call `bundler.bundleOnedir()` for `mode = "onedir"`.
- [x] Keep `mode = "onefile"` as a structured `NotImplementedError`.
- [x] Update CLI bundle rendering so `luai -c --onedir` exits zero and prints the executable path on success.
- [x] Run direct CLI checks for runtime, student management, and savinglua samples.

## Task 5: Documentation And Verification

- [x] Update README and README-zh to state Linux onedir status and boundaries.
- [x] Update ROAD_MAP phase checkboxes for the parts now verified.
- [x] Update `luainstaller.1` enough to stop promising stale legacy behavior.
- [x] Run `luac -p src/*.lua`.
- [x] Run `lua test/smoke_all.lua`.
- [x] Run `luarocks make --tree /tmp/luainstaller-rocktree luainstaller-1.0.0-1.rockspec`.
- [x] Verify `git status --short --branch`.
