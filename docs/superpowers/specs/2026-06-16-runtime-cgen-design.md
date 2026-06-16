# Pure Lua Runtime Searcher And Cgen Design

Date: 2026-06-16

## Purpose

Advance `luainstaller` through `ROAD_MAP.md` Phase 5 by creating the pure Lua
runtime searcher and bootstrap code generator that future C launcher work can
embed.

This milestone should prove that a manifest plus Lua source payload can run
without using the original project files through `package.path`.

## Approaches

### Runtime Only

Implement `src/runtime.lua` with an installable searcher and test it directly.
This is useful but does not prove that generated launchers can carry their own
payload.

### Generated Script Only

Have `src/cgen.lua` emit a full script with an inline searcher. This proves the
bootstrap path but makes runtime behavior harder to reuse in the C launcher.

### Recommended: Runtime Plus Cgen

Keep `src/runtime.lua` as the reusable searcher/runtime library, and have
`src/cgen.lua` generate a bootstrap script that embeds a tiny copy of that
runtime logic plus the payload table. This gives isolated unit tests for runtime
behavior and an end-to-end generated bootstrap test.

## Scope

This milestone includes:

- Implementing `src/runtime.lua`.
- Implementing `src/cgen.lua`.
- Installing both modules through the rockspec.
- Generating a Lua bootstrap chunk with embedded Lua sources.
- Installing a bundled Lua module searcher ahead of normal filesystem searchers.
- Supporting source chunks by module name and entry id.
- Stripping UTF-8 BOM and shebang before loading source.
- Preserving `arg` semantics for generated bootstraps.
- Verifying generated bootstraps for:
  - a single-file sample
  - a multi-file pure Lua sample

This milestone excludes:

- C source generation.
- Native module extraction.
- `.luai/` directory writing.
- Archive payloads.
- Onefile executable output.
- Running projects that require native modules.

## Runtime API

`src/runtime.lua` should expose:

```lua
local runtime = require("luainstaller.runtime")

runtime.stripSource(source)
runtime.install(payload)
runtime.run(payload, run_args)
```

Payload shape:

```lua
{
    entry = {
        id = "__entry__",
        source = "...",
        path = "test/app/main.lua",
    },
    modules = {
        ["model"] = {
            source = "...",
            path = "test/app/model.lua",
        },
    },
}
```

`install(payload)` installs a searcher that:

- checks `payload.modules[module_name]`
- strips BOM/shebang
- loads source with a readable chunk name
- returns the loader function and resolved path when found
- returns a normal Lua searcher miss string when not found

`run(payload, run_args)` should:

- preserve the caller's existing global `arg`
- set `_G.arg` to a new table for the entry chunk
- place the entry path at `arg[0]`
- copy `run_args` into `arg[1..n]`
- install the bundled searcher
- load and execute the entry source
- restore the old `arg` and remove the installed searcher after execution

## Cgen API

`src/cgen.lua` should expose:

```lua
local cgen = require("luainstaller.cgen")

cgen.moduleNameFromPath(path)
cgen.buildPayload(opts)
cgen.generateBootstrap(opts)
```

`buildPayload(opts)` accepts:

- `entry`
- `dependencies`
- `module_names` override map, optional

It should read Lua dependency files, derive module names from paths, and build
the runtime payload table.

`generateBootstrap(opts)` returns Lua source text. The generated source should:

- embed the payload as Lua string literals
- define the minimal runtime functions needed to install the bundled searcher
  and run the entry
- pass through process arguments from the generated script's `arg`
- return the entry chunk result

## Module Name Derivation

For this milestone, derive names conservatively from dependency basenames:

- `test/app/model.lua` -> `model`
- `test/app/reports.lua` -> `reports`
- `test/app/foo/init.lua` -> `foo`

This is enough for the current sample apps, which use simple `require("model")`
style imports. Full module-id derivation from manifest destinations can evolve
in the onedir bundler milestone.

## Error Handling

Runtime and cgen functions may throw structured errors for programmer mistakes:

- missing entry path
- unreadable source file
- duplicate derived module name
- missing entry source
- failed `load`

The CLI/API does not need to expose these functions yet, so direct Lua errors
are acceptable in this milestone as long as tests cover the normal path.

## Testing

Add smoke coverage that:

- `runtime.stripSource()` removes UTF-8 BOM and shebang.
- `runtime.install()` lets `require("module")` load from payload modules.
- `runtime.run()` executes an entry and restores `_G.arg`.
- `cgen.generateBootstrap()` creates Lua source that runs:
  - `test/single_file/01_hello_luainstaller.lua`
  - a pure Lua multi-file fixture

Use a small generated fixture under `test/runtime_bundle/` rather than native
module samples. This keeps Phase 5 focused on pure Lua runtime behavior.

## Documentation

Update README and README-zh to state that the project now has a pure Lua runtime
bootstrap generator for pure Lua payloads, while executable generation and
native module support remain later roadmap work.
