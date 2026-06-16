# C Launcher Template Design

## Goal

Advance `luainstaller` through `ROAD_MAP.md` Phase 6 by adding a small,
auditable C launcher template that can create a Lua state, expose normal
launcher `arg` semantics, run an embedded Lua bootstrap chunk, and report errors
with a traceback. This phase does not yet build onedir output or copy native
modules; it creates the launcher foundation that those milestones will drive.

## Context

Phase 5 added `luainstaller.runtime` and `luainstaller.cgen`. `cgen` can already
produce a Lua bootstrap chunk containing the bundled payload and the minimal
runtime searcher. Phase 6 should embed that generated chunk into C and execute it
through the Lua C API.

The roadmap target is Lua 5.5.0, but the current development environment uses
Lua 5.4. The launcher should avoid Lua-version-specific APIs where possible so
the template can move to Lua 5.5 when the project baseline changes.

## Approaches Considered

### Approach A: Keep Generating Pure Lua Only

This would postpone C until onedir exists. It keeps tests simple, but it does
not move the project toward the roadmap's launcher requirement.

### Approach B: Full Platform Launcher Now

This would add POSIX and Windows executable-path helpers, native path rewriting,
static and shared Lua profiles, and build commands in one pass. It moves quickly
on paper but would mix too many unverified contracts before the first C template
is trusted.

### Approach C: Minimal Shared-Lua Launcher Template First

Add a small C file plus a Lua-side generator that writes an embedded byte array.
The generated C should compile on the current host through `pkg-config lua`, run
the Phase 5 bootstrap, preserve `arg`, and print traceback errors. Platform
helpers are stubbed or kept behind narrow functions so Phase 7 can use them.

Chosen approach: C. It proves the end-to-end launcher shape while keeping the
implementation focused and testable.

## Scope

In scope:

- Add `src/launcher/luai_launcher.c` as the checked-in C template.
- Add Lua generation support that converts a bootstrap string into C source with
  explicit byte lengths.
- Keep the first executable profile as shared Lua, linked against the local Lua
  library.
- Install the new generator module through the rockspec.
- Add smoke coverage that generates a launcher for `test/runtime_bundle/main.lua`,
  compiles it when `cc` and `pkg-config lua` are available, runs it, and verifies
  output and `arg` behavior.
- Document that static Lua and Windows CRT policy are still roadmap work.

Out of scope:

- `--onedir` directory construction.
- `--onefile` payload archives.
- Copying native modules or companion shared libraries.
- Lua 5.5-specific builds.
- Windows XP build verification.

## Components

### `src/launcher/luai_launcher.c`

The template owns process startup. It should:

- include Lua headers through normal `lua.h`, `lauxlib.h`, and `lualib.h`;
- expect generated symbols `luai_bootstrap` and `luai_bootstrap_size`;
- create a Lua state with `luaL_newstate`;
- open standard libraries with `luaL_openlibs`;
- create a global `arg` table preserving `argv[0]` at index `0` and user
  arguments from index `1`;
- load the embedded bootstrap with `luaL_loadbufferx` when available, otherwise
  `luaL_loadbuffer`;
- execute with a traceback error handler;
- print failures to `stderr` and return a nonzero exit code.

The template should stay under one screen of C where practical. Future platform
helpers can be added as separate files once executable path and `.luai` lookup
are required.

### `src/launcher.lua`

This Lua module owns launcher source generation:

```lua
local launcher = require("luainstaller.launcher")

launcher.bytesFromString(source)
launcher.generateSource({
    entry = "test/runtime_bundle/main.lua",
    dependencies = { scripts = { "test/runtime_bundle/greeter.lua" } },
})
```

`generateSource(opts)` should use `luainstaller.cgen.generateBootstrap(opts)` and
return a single C translation unit that defines the bootstrap byte array before
including or appending the launcher template.

The first implementation may load `src/launcher/luai_launcher.c` relative to the
current checkout or from an explicit `template_path`. Later packaging work can
make installed template discovery more robust.

### CLI and API

This phase should not change `luainstaller.bundle(opts)` from planning mode to
real output. That switch belongs to Phase 7. The new module is a build primitive
consumed by tests and future bundler work.

## Error Handling

Lua generator errors should be structured where they represent programmer input:

- `InvalidOptionsError` when `entry` is missing.
- `ScriptNotFoundError` when input files cannot be read.
- `LauncherTemplateNotFoundError` when the template path cannot be read.

C runtime errors should print a clear message and traceback to `stderr`.

## Testing

Add smoke coverage that:

- verifies generated C contains an explicit byte array and byte count;
- verifies generated C parses the same pure Lua payload used by Phase 5;
- compiles the generated C when `cc` and `pkg-config lua` are available;
- runs the compiled launcher with an argument and expects:
  - `hello launcher`;
  - `entry=test/runtime_bundle/main.lua`.

When the compiler toolchain is missing, the smoke test may skip the compile/run
portion with a clear printed reason. Syntax and generator checks must still run.

## Documentation

Update README and README-zh after implementation to state that the project now
has a shared-Lua C launcher template for generated pure Lua bootstrap chunks,
while real `--onedir` output and native module copying remain planned.

## Acceptance Criteria

- `src/launcher/luai_launcher.c` exists and compiles on the current host.
- `src/launcher.lua` generates C source with `luai_bootstrap` and
  `luai_bootstrap_size`.
- The generated launcher runs the runtime fixture through the embedded
  bootstrap when local Lua C build dependencies are available.
- `lua test/smoke_all.lua` passes.
- `luac -p src/*.lua` passes.
- `luarocks make --local luainstaller-1.0.0-1.rockspec` installs the new module.
