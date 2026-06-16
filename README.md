# luainstaller

*[中文](README-zh.md)*

`luainstaller` is a tool that packages Lua projects into **distributable executables**, supporting **Windows** and **Linux**. It is open-sourced on [GitHub](https://github.com/Water-Run/luainstaller) and licensed under **LGPL**.

`luainstaller` provides dependency analysis and single-file bundling capabilities, and can package non-pure-Lua content inside the wrapper program. It is important to note that `luainstaller` guarantees that the packaged binary will run on the same **system environment** as yours (excluding the `lua` environment itself).

> `luainstaller` was previously provided as a Python library. Older versions were out-of-the-box and cross-platform, but could only bundle pure Lua scripts. (See the `deprecated-python-lib` branch)

---

## Installation

Install via `luarocks`:

```bash
luarocks install luainstaller
```

---

## Usage

`luainstaller` can be used as a CLI tool or invoked directly from Lua scripts.

---

### Command-Line Tool (CLI)

CLI command name: `luai`.

```bash
luai --help
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c --onedir test/student_management_system/main.lua -o build/student-manager
```

Current command status:

| Command | Status | Description |
|---------|--------|-------------|
| `luai -a <entry.lua>` | implemented | Analyze Lua and native module dependencies. |
| `luai -t <entry.lua>` | implemented | Print analyzer trace records with classifications and reasons. |
| `luai -c <entry.lua>` | planned | Validate and plan bundling, then return `NotImplementedError` until the onedir bundler exists. |

Common options:

| Option | Description |
|--------|-------------|
| `--onedir` | Directory bundle mode. This is the default planned output mode. |
| `--onefile` | Single-file bundle mode, planned after onedir. |
| `-o, --out <path>` | Output path for bundle planning. |
| `--include <path>` | Manually include a dependency; repeatable. |
| `--exclude <path>` | Exclude a dependency by path or basename; repeatable. |
| `--no-depscan` | Disable automatic dependency scanning. |
| `--max-deps <n>` | Maximum dependency count, default `36`. |
| `--verbose` | Request more detailed output where available. |

---

### Lua API

The Lua API uses the same parameter semantics as the CLI. Dependency scanning is enabled by default; set `depscan = false` to disable it.

```lua
local luainstaller = require("luainstaller")
```

---

#### Structured Results

The public API returns result tables instead of throwing for normal user errors.

```lua
local analyzed = luainstaller.analyze({
  entry = "test/student_management_system/main.lua",
  max_deps = 250,
})

if analyzed.ok then
  print(#analyzed.dependencies.scripts)
else
  io.stderr:write(analyzed.error.type .. ": " .. analyzed.error.message .. "\n")
end
```

Available functions:

| Function | Status | Return shape |
|----------|--------|--------------|
| `luainstaller.analyze(opts)` | implemented | `{ ok = true, action = "analyze", dependencies = { scripts = {}, libraries = {} } }` |
| `luainstaller.trace(opts)` | implemented | Real analyzer trace records with requiring file, source line, candidates, classification, and reason. |
| `luainstaller.bundle(opts)` | planned | Returns `NotImplementedError` with `error.manifest` after validation. |

Common `opts` fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `entry` | string | required | Entry script path. |
| `mode` | string | `"onedir"` | `onedir` or `onefile` for bundle planning. |
| `out` | string | nil | Output path for bundle planning. |
| `max_deps` | number | `36` | Maximum dependency count. |
| `include` | string[] | `{}` | Extra files to include. |
| `exclude` | string[] | `{}` | Paths or basenames to exclude. |
| `depscan` | boolean | `true` | Set `false` for manual-only dependencies. |

---

## How It Works

The current workflow is: **analyze entry script → collect dependencies → trace
resolution decisions → validate bundle options**.

Runtime launcher generation, manifest writing, onedir output, onefile payloads,
and native-module extraction are roadmap work. The compatibility boundary for
that runtime work is same OS, same architecture, same ABI, and same Lua ABI.

`bundle(opts)` now builds the manifest contract used by future onedir and
launcher work before returning its current `NotImplementedError`; writing that
manifest to `.luai/manifest.lua` is still part of the onedir bundler milestone.

The overall process can be summarized as:

```plaintext
[entry.lua]
     |
     v
[Static Dependency Analysis]
     |
     v
[Collect Lua files / manual --include / --exclude]
     |
     v
[Validate bundle plan]
     |
     v
[Manifest / onedir runtime work in progress]
```
