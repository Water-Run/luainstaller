# CLI/API Reset Design

Date: 2026-06-16

## Purpose

Move `luainstaller` from the legacy `luainstaller analyze/build` interface
toward the roadmap contract:

- CLI command: `luai`
- Library import: `require("luainstaller")`
- Primary CLI actions: `luai -a`, `luai -t`, and `luai -c`
- First output target: `--onedir`
- Compatibility promise: same OS, same architecture, same ABI, same Lua ABI

This reset is a foundation milestone. It should make the public entry points
honest, testable, and aligned with `ROAD_MAP.md` before deeper runtime,
manifest, native-module, or C launcher work starts.

## Scope

This milestone includes:

- Registering the LuaRocks CLI executable as `luai`.
- Reworking CLI parsing around:
  - `luai -a <entry>` for dependency analysis.
  - `luai -t <entry>` for trace-oriented dependency diagnostics.
  - `luai -c <entry>` for compile/bundle planning.
- Supporting common options at parse and API boundaries:
  - `--onedir`
  - `--onefile`
  - `-o <path>` / `--out <path>`
  - `--include <path>`
  - `--exclude <path-or-module>`
  - `--no-depscan`
  - `--verbose`
  - `--max-deps <n>`
- Exposing target public API functions:
  - `luainstaller.analyze(opts)`
  - `luainstaller.trace(opts)`
  - `luainstaller.bundle(opts)`
- Returning structured API results and structured errors.
- Updating README, README-zh, coding style, and rockspec to state the current
  contract instead of the legacy command shape.
- Restoring a useful smoke-test baseline for syntax, analyzer visibility, and
  the new CLI entry points.

This milestone excludes:

- A working C launcher.
- A real `--onefile` archive format.
- Automatic native dependency closure.
- Cross-compilation.
- Claims that generated bundles already run without a Lua installation.

## Architecture

Keep the implementation small and layered.

### CLI Layer

`src/cli.lua` should own argument parsing, user-facing output, and process exit
codes only. It should translate command-line flags into option tables and call
the public API in `src/init.lua`.

Recommended parser shape:

- Action flags are mutually exclusive: `-a`, `-t`, `-c`.
- The first non-option argument after the action is the entry script.
- Repeatable options such as `--include` and `--exclude` append to arrays.
- `--onedir` is the default bundle mode.
- `--onefile` is accepted but may return a structured not-implemented result
  until the payload milestone exists.
- Legacy commands may either be removed or kept as compatibility aliases only if
  they are clearly labeled and covered by tests. The roadmap target remains
  `luai`.

### Public API Layer

`src/init.lua` should be the stable library boundary.

`analyze(opts)`:

- Requires `opts.entry`.
- Uses the existing analyzer when `opts.depscan ~= false`.
- Adds explicit includes after validation.
- Applies excludes before returning results where possible.
- Returns `{ ok = true, action = "analyze", dependencies = ... }` on success.
- Returns `{ ok = false, error = { type = ..., message = ... } }` on failure.

`trace(opts)`:

- Requires `opts.entry`.
- Initially may wrap analyzer output into coarse trace records.
- Should keep the output format compatible with the future traceable analyzer:
  requiring file, requested module, selected path/type, and failure reason.
- Returns structured results, even if early trace detail is incomplete.

`bundle(opts)`:

- Requires `opts.entry`.
- Accepts `opts.mode = "onedir"` or `"onefile"`.
- Performs validation and dependency planning first.
- Until a real bundler exists, returns a structured `NotImplementedError` after
  successful validation.
- Must not pretend that an executable was generated.

Existing helpers such as log management may remain, but they are not the public
surface being advanced in this milestone.

### Analyzer Layer

Keep `src/analyzer.lua` as the base. Do not replace its lexer or resolver in
this milestone.

The analyzer changes should be limited to what is needed for the reset:

- Stable structured errors.
- CLI/API-friendly result conversion.
- Enough trace hooks or wrappers for `luai -t` to provide useful diagnostics.
- Fixes needed to make current smoke tests pass.

Native module classification can remain basic until the traceable analyzer and
manifest phases.

### Packaging Metadata

The rockspec should:

- Keep the package name `luainstaller`.
- Install the executable as `luai`.
- Depend on the intended Lua baseline from the roadmap.
- List only modules that exist in the repository.

The repository should not reference missing implementation modules as installed
modules. If a future module is not present, docs may describe it as planned, but
packaging metadata must stay truthful.

## Data Flow

`luai -a entry.lua`

1. CLI parses action and options.
2. CLI calls `luainstaller.analyze(opts)`.
3. API validates the entry and options.
4. API invokes analyzer unless `depscan` is disabled.
5. API merges manual includes and excludes.
6. CLI renders dependency output.
7. Process exits `0` on success or `1` on structured failure.

`luai -t entry.lua`

1. CLI parses action and options.
2. CLI calls `luainstaller.trace(opts)`.
3. API builds trace records from current analyzer behavior.
4. CLI renders concise diagnostics showing what was found and what was skipped
   or missing.

`luai -c entry.lua --onedir -o dist/app`

1. CLI parses action and options.
2. CLI calls `luainstaller.bundle(opts)`.
3. API validates output mode and entry.
4. API analyzes dependencies or uses manual mode.
5. API returns `NotImplementedError` until manifest and onedir bundler work is
   implemented.
6. CLI prints a clear error that bundling is planned but not yet available.

## Error Handling

Every public API function should return structured tables rather than throwing
for normal user errors.

Required error shape:

```lua
{
    ok = false,
    error = {
        type = "ScriptNotFoundError",
        message = "Lua script not found: path/to/file.lua",
    },
}
```

CLI handlers should convert this shape into readable stderr output and nonzero
exit codes.

Programming errors may still throw, but missing files, invalid options,
dependency limits, unresolved modules, and not-yet-implemented bundle modes
should use structured results.

## Documentation

Documentation should distinguish three states:

- Implemented now.
- Accepted and planned by the current interface.
- Future runtime behavior.

README and README-zh should avoid implying that `--onedir` or `--onefile`
already creates a working self-contained executable until implementation and
verification prove it.

Coding style should state the Lua 5.5.0-first policy from `ROAD_MAP.md`. If the
local development environment still uses Lua 5.4, note that as a temporary
development constraint, not as the project baseline.

## Testing

Minimum verification for this milestone:

- `lua -v`
- `luac -p src/*.lua`
- `lua test/smoke_all.lua`
- `lua src/cli.lua --help`
- `lua src/cli.lua -a test/student_management_system/main.lua`
- `lua src/cli.lua -t test/student_management_system/main.lua`
- `lua src/cli.lua -c --onedir test/student_management_system/main.lua -o build/student-manager`
- `luarocks make luainstaller-1.0.0-1.rockspec`

Expected result for the final `-c` command during this milestone may be a
structured not-implemented failure, as long as parsing, validation, and messaging
are correct and tests assert that behavior explicitly.

## Open Decisions

The implementation plan must decide:

- Whether to remove legacy `luainstaller analyze/build` commands immediately or
  keep short-term compatibility aliases.
- Whether the Lua 5.5.0 rockspec dependency can be enforced now, given the local
  environment currently reports Lua 5.4.8.
- How much trace detail to expose before the full traceable analyzer phase.

Recommended defaults:

- Keep compatibility aliases only if they add little code and do not confuse
  help output.
- Do not make local development impossible solely because Lua 5.5 is not yet
  installed; document the intended baseline while keeping verification runnable.
- Start `trace` with coarse records and evolve it in Phase 3.
