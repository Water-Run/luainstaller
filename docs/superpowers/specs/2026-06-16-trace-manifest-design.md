# Traceable Analyzer And Manifest Design

Date: 2026-06-16

## Purpose

Advance `luainstaller` from coarse dependency summaries to a traceable build
plan. This milestone covers `ROAD_MAP.md` Phase 3 and Phase 4:

- Produce trace records from the analyzer itself.
- Classify every observed `require` decision.
- Treat `pcall(require, "...")` as optional in trace output.
- Introduce a manifest module that turns analyzer output, manual inputs, and
  bundle options into the contract consumed by future runtime, bundler, and
  launcher work.

This milestone still does not generate an executable, write `.luai/`, or build
the C launcher.

## Scope

This milestone includes:

- Extending `src/analyzer.lua` without replacing its lexer or resolver.
- Adding trace records with:
  - requiring file
  - source line
  - requested module
  - optional flag
  - candidate templates or candidates
  - selected path
  - selected type
  - classification
  - reason
- Classifying results as `builtin`, `lua`, `native`, `missing`, or `excluded`.
- Preserving strict dependency errors for non-optional missing modules, circular
  dependencies, dynamic requires, and dependency limits.
- Adding `src/manifest.lua`.
- Building manifest tables with normalized forward-slash paths, output mode,
  Lua version, OS, architecture, launcher profile, compatibility notes, source
  paths, destination paths, and content hashes.
- Wiring public API `trace(opts)` and `bundle(opts)` to use the real trace and
  manifest data.
- Keeping `bundle(opts)` a structured `NotImplementedError`, but including the
  generated manifest in error details after validation succeeds.

This milestone excludes:

- JSON output.
- Archive format.
- Runtime searchers.
- File copying into `.luai/`.
- Native external-library dependency closure.
- Duplicate-module conflict automation beyond explicit manifest rejection.

## Architecture

### Analyzer Trace

`src/analyzer.lua` remains the dependency engine. Add trace capability by
recording decisions during recursive analysis.

Recommended data flow:

1. `LuaLexer:extractRequires()` already returns module name and source line.
   Preserve that structure and keep `optional = true` for `pcall(require, ...)`.
2. `ModuleResolver` exposes a new inspection method that returns candidate
   templates/candidates and the selected result instead of only throwing.
3. `DependencyAnalyzer` records one trace item per require before recursing into
   Lua children.
4. `analyzeDependencies()` returns the existing `{ scripts, libraries }` shape
   by default for compatibility.
5. New `traceDependencies()` returns `{ scripts, libraries, trace }`.

Trace item shape:

```lua
{
    requiring_file = "/abs/project/main.lua",
    source_line = 12,
    requested = "foo.bar",
    optional = false,
    candidates = {
        { type = "lua", template = "/abs/project/?.lua", path = "/abs/project/foo/bar.lua" },
    },
    selected_path = "/abs/project/foo/bar.lua",
    selected_type = "lua",
    classification = "lua",
    reason = "resolved",
}
```

For builtins:

```lua
{
    requested = "math",
    selected_type = "builtin",
    classification = "builtin",
    reason = "builtin",
}
```

For optional missing modules:

```lua
{
    requested = "luasql.firebird",
    optional = true,
    selected_type = nil,
    classification = "missing",
    reason = "optional-missing",
}
```

For excluded manual dependencies, public API may add trace items outside the
analyzer:

```lua
{
    requested = "model.lua",
    classification = "excluded",
    reason = "manual-exclude",
}
```

### Manifest Module

Create `src/manifest.lua` with one main constructor:

```lua
local manifest = require("luainstaller.manifest")
local result = manifest.build(opts)
```

The constructor should accept:

- `entry`
- `mode`
- `out`
- `dependencies`
- `trace`
- `include`
- `exclude`
- `depscan`
- `launcher_profile`

Manifest shape:

```lua
{
    version = 1,
    entry = {
        source_path = "/abs/project/main.lua",
        destination_path = ".luai/lua/main.lua",
    },
    output = {
        mode = "onedir",
        path = "build/app",
    },
    lua = {
        version = "Lua 5.4",
        abi = "lua5.4",
    },
    platform = {
        os = "linux",
        arch = "x86_64",
    },
    launcher = {
        profile = "shared-lua",
    },
    modules = {
        lua = {},
        native = {},
        external = {},
    },
    manual = {
        include = {},
        exclude = {},
        depscan = true,
    },
    trace = {},
    compatibility = {
        "same OS",
        "same architecture",
        "same ABI",
        "same Lua ABI",
    },
}
```

Every file entry should include a stable content hash where the source file can
be read. Use a deterministic pure-Lua hash for now. The first hash does not need
to be cryptographic; it must be stable and clearly labeled so it can be replaced
by SHA-256 later.

### Duplicate Module Handling

The first duplicate check should be narrow:

- Compute module ids for Lua files from their destination path.
- Reject duplicate destination paths with different source paths.
- Return a structured `DuplicateModuleError`.

Do not try to infer every possible Lua module alias in this milestone.

## Public API

`luainstaller.trace(opts)` should call the analyzer trace path and return real
trace records.

`luainstaller.bundle(opts)` should:

1. Validate options.
2. Analyze dependencies and collect trace.
3. Build a manifest.
4. Return `NotImplementedError` with `manifest` included in the error table.

`luainstaller.analyze(opts)` should keep returning the dependency summary shape
from the previous milestone.

## CLI

`luai -t` should render the richer trace. Keep the text output concise:

```text
trace.
entry.lua
  1) lua resolved module.name -> /abs/path/module/name.lua
  2) builtin builtin math
  3) missing optional-missing luasql.firebird
```

`luai -c` may still exit nonzero with `NotImplementedError`. No manifest text
dump is required by default, but the API must expose the manifest for tests and
future bundler work.

## Testing

Add smoke coverage for:

- `luainstaller.trace()` includes requiring file, source line, requested module,
  candidate list, classification, and reason.
- `pcall(require, "luasql.firebird")` appears as `optional = true` and
  `classification = "missing"` when the module is not installed.
- Builtin modules appear in trace as `classification = "builtin"`.
- `luainstaller.bundle()` returns `NotImplementedError` with a manifest.
- Manifest includes Lua modules, native modules, trace, output mode, platform,
  Lua info, compatibility notes, and stable hashes.
- `luarocks make --local luainstaller-1.0.0-1.rockspec` installs the new
  `luainstaller.manifest` module.

## Documentation

Update README and README-zh to say that `luai -t` now shows analyzer trace
records and `bundle(opts)` returns a planned manifest with its current
`NotImplementedError`.

## Open Decisions

- The first hash is deterministic but not cryptographic. The manifest should
  label it clearly, for example `hash_algorithm = "fnv1a32"`.
- OS and architecture detection may use `uname` on Unix-like systems and simple
  environment checks on Windows until a dedicated compat module exists.
- `external` classification remains reserved for future explicit external
  library handling.
