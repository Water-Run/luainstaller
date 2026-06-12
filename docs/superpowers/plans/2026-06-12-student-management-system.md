# Student Management System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `test/student_management_system` into a complete LuaRocks-backed sample project using `cjson`, JSON storage, reports, command mode, and smoke verification.

**Architecture:** Keep the sample as a small multi-file Lua application. `main.lua` handles CLI/menu flow, `model.lua` validates records, `storage.lua` owns JSON persistence, `service.lua` owns mutations and queries, `reports.lua` computes summaries, and `utils.lua` holds terminal/file helpers.

**Tech Stack:** Lua 5.4, `cjson`, standard Lua libraries, shell smoke test through Lua.

---

### Task 1: Smoke Test

**Files:**
- Create: `test/student_management_system/smoke_test.lua`

- [x] Write a smoke test that seeds a temporary JSON file, lists students, runs reports, exports CSV, imports CSV, and verifies analyzer-visible `cjson`.
- [x] Run it before implementation and confirm it fails on missing command-mode behavior.

### Task 2: Application Modules

**Files:**
- Modify: `test/student_management_system/model.lua`
- Modify: `test/student_management_system/storage.lua`
- Modify: `test/student_management_system/service.lua`
- Modify: `test/student_management_system/reports.lua`
- Modify: `test/student_management_system/utils.lua`
- Modify: `test/student_management_system/main.lua`

- [x] Implement JSON-backed storage with temporary-file save.
- [x] Implement validated student records and grade calculations.
- [x] Implement service operations: seed, add, update, delete, list, search, reports, import/export.
- [x] Implement command mode and retain interactive mode.

### Task 3: Documentation And Verification

**Files:**
- Modify: `test/student_management_system/README.md`

- [x] Document dependencies, commands, data files, direct run, and future `luai` packaging checks.
- [x] Run syntax checks, smoke test, analyzer check, and command examples.
- [x] Commit and push.
