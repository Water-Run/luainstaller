# luainstaller

*[中文](README-zh.md)*

`luainstaller` is a tool that packages Lua projects into **distributable executables**, supporting **Windows** and **Linux**. It is open-sourced on [GitHub](https://github.com/Water-Run/luainstaller) and licensed under **LGPL**.

`luainstaller` provides dependency analysis and Linux directory bundling
capabilities, and can package non-pure-Lua content inside the wrapper program.
It is important to note that `luainstaller` guarantees that the packaged binary
will run on the same **system environment** as yours. A separate `lua` command
is not required for Linux onedir bundles, but system ABI and native library
compatibility still matter.

> `luainstaller` was previously provided as a Python library. Older versions were out-of-the-box and cross-platform, but could only bundle pure Lua scripts. (See the `deprecated-python-lib` branch)

---

## Installation

Install via `luarocks`:

```bash
luarocks install luainstaller
```

Install from a source checkout when LuaRocks is unavailable:

```bash
sh tools/install-source.sh --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
luai --help
```

This source installer only needs a `lua` command. Building Linux `--onedir`
bundles still requires the local C toolchain and Lua development metadata, such
as `cc`, Lua headers, and `pkg-config` data for Lua.

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
| `luai -c <entry.lua>` | implemented on Linux for `--onedir` | Build a directory bundle with a launcher, manifest, embedded Lua payload, and copied native Lua C modules. |

Common options:

| Option | Description |
|--------|-------------|
| `--onedir` | Directory bundle mode. This is the default output mode on Linux. |
| `--onefile` | Single-file bundle mode, planned after onedir. |
| `-o, --out <path>` | Output path for bundle actions. |
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
| `luainstaller.bundle(opts)` | implemented on Linux for `mode = "onedir"` | Returns `{ ok = true, action = "bundle", executable = "...", manifest = { ... } }`; `onefile` still returns `NotImplementedError`. |

Common `opts` fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `entry` | string | required | Entry script path. |
| `mode` | string | `"onedir"` | `onedir` or `onefile`. |
| `out` | string | nil | Output directory path for `onedir`. |
| `max_deps` | number | `36` | Maximum dependency count. |
| `include` | string[] | `{}` | Extra files to include. |
| `exclude` | string[] | `{}` | Paths or basenames to exclude. |
| `depscan` | boolean | `true` | Set `false` for manual-only dependencies. |

---

## How It Works

The current workflow is: **analyze entry script → collect dependencies → trace
resolution decisions → build a Linux onedir bundle**.

Linux `--onedir` output is implemented. It generates a shared-Lua launcher,
writes `.luai/manifest.lua`, embeds Lua payloads in the launcher, copies the
linked Lua shared runtime into `.luai/native/`, and copies detected native Lua C
modules into `.luai/native/`. The compatibility boundary is same OS, same
architecture, same ABI, and same Lua ABI.

`--onefile` payloads, cross-platform bundle output, and automatic external
shared-library dependency closure are still roadmap work.

For detailed implementation notes, non-pure-Lua behavior, verification commands,
and current limitations, see
[`docs/LINUX-ONEDIR-BUNDLING.md`](docs/LINUX-ONEDIR-BUNDLING.md).

The pure Lua runtime milestone is implemented: `luainstaller.runtime` can install
a bundled module searcher, and `luainstaller.cgen` can generate a Lua bootstrap
chunk for pure Lua payloads. This bootstrap is the Lua side that future C
launcher work will embed.

The C launcher template milestone is implemented: `luainstaller.launcher` can
generate shared-Lua C source that embeds the Lua bootstrap and executes it
through the Lua C API. The Linux onedir bundler uses this generator to produce
the executable in the output directory.

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
[Generate C launcher / copy Lua runtime and native modules / write manifest]
     |
     v
[Linux onedir bundle]
```
