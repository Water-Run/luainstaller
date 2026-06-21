# Linux Onedir Code Review

Date: 2026-06-21

## Scope

This review covers the Linux `--onedir` implementation and related documentation
on branch `codex/linux-onedir-demo-validation`.

Reviewed areas:

- `src/bundler.lua`
- `src/cgen.lua`
- `src/init.lua`
- `src/cli.lua`
- `test/smoke_all.lua`
- `README.md`
- `README-zh.md`
- `ROAD_MAP.md`
- `luainstaller.1`
- `test/README.md`
- `docs/IMPLEMENTATION-RESEARCH.md`
- Linux onedir design and plan documents

## Findings And Actions

### Manifest Did Not Record Copied Lua Runtime

Severity: important.

The bundler copied `liblua-5.4.so` into `.luai/native/`, but the generated
manifest did not record that runtime file. That made `.luai/manifest.lua`
incomplete as a description of the output directory.

Action taken:

- Added a smoke assertion that loads `.luai/manifest.lua` and checks
  `manifest.launcher.lua_runtime`.
- Updated `src/bundler.lua` so `copyLuaRuntime()` returns a runtime record.
- Moved manifest writing after launcher compilation and Lua runtime copying.
- Added `launcher.lua_runtime.source_path` and
  `launcher.lua_runtime.destination_path`.

### Documentation Was Stale In Edge Files

Severity: important.

`docs/IMPLEMENTATION-RESEARCH.md` still described early placeholder modules,
old CLI behavior as current, and LuaRocks metadata as broken. `test/README.md`
still described the `luai` interface as future behavior.

Action taken:

- Rewrote `docs/IMPLEMENTATION-RESEARCH.md` to describe the current module map,
  implemented first-stage shape, verification targets, and remaining risks.
- Updated `test/README.md` to describe current Linux `--onedir` packaging.

### Detailed Linux Onedir Documentation Was Missing

Severity: important.

README and manpage summaries were accurate but too short for maintainers and
users who need to understand non-pure-Lua packaging and current limits.

Action taken:

- Added `docs/LINUX-ONEDIR-BUNDLING.md`.
- Linked the new document from README, README-zh, and manpage.
- Documented output layout, build pipeline, runtime flow, non-pure-Lua module
  copying, bundled Lua shared runtime, manifest fields, verified examples,
  commands, limitations, and onefile direction.

### Clean Environment Claim Needed More Precision

Severity: moderate.

The older wording implied "excluding the Lua environment itself" without
explaining the difference between the `lua` command and system ABI/runtime
dependencies.

Action taken:

- Updated README, README-zh, and manpage to state that Linux onedir bundles do
  not require a separate `lua` command, while still requiring compatible system
  ABI and native libraries.

## Quality Checks

Code and documentation were checked for:

- Lua syntax.
- Project smoke coverage.
- LuaRocks installation through a temporary tree.
- Stale public documentation text.
- Trailing whitespace and tab issues, allowing roff table tabs in the manpage.
- Linux no-`lua` container runtime behavior.

## Known Remaining Limitations

- `--onefile` is still not implemented.
- This Linux-focused review did not cover macOS output. macOS `--onedir` was
  implemented and verified later in `docs/CROSS-PLATFORM-TEST-MATRIX.md`.
- Windows output is not implemented.
- External shared library closure is not automatic.
- Legacy compatibility helpers still exist in the CLI implementation.
- Older superpowers plan/spec files are historical records and may describe
  earlier milestone expectations rather than current behavior.
