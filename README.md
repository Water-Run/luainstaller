# luainstaller

*[中文](README-zh.md)*

`luainstaller` is a tool that packages Lua projects into **distributable executables**, supporting **Windows** and **Linux**. It is open-sourced on [GitHub](https://github.com/Water-Run/luainstaller) and licensed under **LGPL**.

`luainstaller` provides dependency analysis and single-file bundling capabilities, and can package non-pure-Lua content inside the wrapper program. It is important to note that `luainstaller` guarantees that the packaged binary will run on the same **system environment** as yours (excluding the `lua` environment itself).

> `luainstaller` was previously provided as a Python library. Older versions were out-of-the-box and cross-platform, but could only bundle pure Lua scripts. (See the `deprecated-python-lib` branch)

---

## Development Plan

The next development stage will keep the project small and focus on a verifiable minimum loop: package Lua projects into ready-to-run executables for the **same operating system, architecture, and ABI** as the build environment. For example, an artifact built on WinXP should primarily target WinXP; Linux and macOS follow the same rule. Cross-system builds are not the first target.

Near-term goals:

- Install through LuaRocks as a library and register the concise `luai` command-line tool. The public library remains available through `require("luainstaller")`.
- Restore and unify the command-line entry point with concise Lua-style options, such as `luai -c main.lua` for packaging, `luai -a main.lua` for analysis, and `luai -t main.lua` for dependency tracing.
- Keep `analyzer` as the dependency analysis core, first supporting Lua scripts and Lua C modules (`.so` / `.dll` / `.dylib`) directly discovered through `require`.
- Handle non-pure-Lua projects with runtime extraction in the first stage: collect native modules at packaging time, extract them to a temporary directory at runtime, update `package.cpath`, then execute the entry script.
- Add code tracing output that shows where each `require` came from, which path it resolved to, and whether it was bundled or skipped. This should make dynamic dependency and platform ABI issues easier to diagnose.
- Defer external system library scanning, complex hooks, and cross-platform builds. Use manual includes for those cases first.

---

## Installation

Install via `luarocks`:

```bash
luarocks install luainstaller
```

### Environment Dependencies

Before running, ensure the following dependencies are installed:

- [luastatic](https://github.com/ers35/luastatic)
- A GCC-compatible C toolchain (e.g. `gcc` / `mingw-w64 gcc`)
- `windres` (Windows only; required when using `--icon`)

---

## Usage

`luainstaller` can be used as a CLI tool or invoked directly from Lua scripts.

---

### Command-Line Tool (CLI)

CLI command name: `luainstaller`

Show help:

```bash
luainstaller --help
```

```plaintext
luainstaller v0.1.0

Usage:
  luainstaller bundle <entry.lua> [options]
  luainstaller analyze <entry.lua> [options]
  luainstaller version

Options:
  ...
```

> On Linux, you can also use `man luainstaller` to view the full manual (if the manpage is installed).

---

#### `bundle` — Bundling

`bundle` is the most commonly used command, used to package a Lua project into an executable.

**Default mode** (outputs a directory):

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
success.
<entry.lua> => <output_dir>/
```

By default, `luainstaller` performs **static dependency analysis** starting from the entry `.lua` file and outputs all required runtime files into a directory.

**Single-file mode** (`--onefile`, outputs a single executable):

```bash
luainstaller bundle <path_to_lua_entry_file> --onefile
```

```plaintext
success.
<entry.lua> => <output_file>
```

`--onefile` further wraps the directory bundle output into a **single executable file**.

**Optional parameters:**

| Option                  | Description                                                                                                                          | Example                                                    |
|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| `-o, --out <path>`      | Output path: directory in default mode; file when `--onefile` is enabled                                                             | `--out ../dist/` / `--onefile --out ../dist/app.exe`       |
| `--onefile`             | Generate a single-file executable (disabled by default)                                                                              | `luainstaller bundle main.lua --onefile`                   |
| `-v, --verbose`         | Print more detailed analysis and bundling logs                                                                                       | `luainstaller bundle main.lua --verbose`                   |
| `--max-deps <n>`        | Maximum number of dependencies (default: 36)                                                                                         | `luainstaller bundle main.lua --max-deps 100`              |
| `--include <path>`      | Manually include dependencies (repeatable; for dynamic `require` and other cases static analysis cannot detect)                      | `--include ./require.lua --include ./plugin.lua`           |
| `--exclude <path>`      | Manually exclude dependencies (repeatable; to remove false positives such as `pcall(require, ...)`; takes priority over `--include`) | `luainstaller bundle main.lua --exclude ./test_utils.lua`  |
| `--no-depscan`          | Disable dependency scanning, entering fully manual mode (all dependencies must be specified via `--include`)                         | `--no-depscan --include ./a.lua --include ./b.lua`         |
| `--icon` (Windows only) | Set the application icon (`.ico` file)                                                                                               | `luainstaller bundle main.lua --onefile --icon ./logo.ico` |

---

#### `analyze` — Dependency Analysis

Perform dependency analysis only, without bundling:

```bash
luainstaller analyze <path_to_lua_entry_file>
```

```plaintext
success.
N dependencies found:
  1) ...
  2) ...
```

---

### Lua API

The Lua API uses the same parameter semantics as the CLI. Dependency scanning is enabled by default; set `depscan = false` to disable it.

```lua
local luainstaller = require("luainstaller")
```

---

#### `bundle` — Bundling

**Function signature**

```lua
local ok, out = luainstaller.bundle(opts)
```

Return values: when `ok=true`, `out` is the output path; when `ok=false`, `out` is an error message string.

**Parameters (`opts` table)**

| Parameter  | Type     | Default  | Description                                                                                        |
|------------|----------|----------|----------------------------------------------------------------------------------------------------|
| `entry`    | string   | required | Entry script path                                                                                  |
| `out`      | string   | —        | Output path (directory path when `onefile=false`; file path when `onefile=true`)                   |
| `onefile`  | boolean  | `false`  | Single-file mode switch                                                                            |
| `verbose`  | boolean  | `false`  | Whether to output detailed logs                                                                    |
| `max_deps` | number   | `36`     | Maximum number of dependencies                                                                     |
| `include`  | string[] | `{}`     | Manually include dependencies (for dynamic `require` and other cases that cannot be auto-detected) |
| `exclude`  | string[] | `{}`     | Manually exclude dependencies (to remove false positives; takes priority over `include`)           |
| `depscan`  | boolean  | `true`   | Whether to enable automatic dependency analysis (`false` is equivalent to CLI `--no-depscan`)      |
| `icon`     | string   | —        | Application icon path (`.ico` file, Windows only)                                                  |

**Examples**

```lua
-- Simplest bundling: outputs a directory by default, automatic dependency scanning
local ok, out = luainstaller.bundle({ entry = "main.lua" })
if ok then print("Bundle succeeded: " .. out)
else      print("Bundle failed: " .. out) end

-- Single-file mode
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  onefile = true,
  out     = "../dist/app.exe",
})

-- Manual dependency management
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  include = { "./lib/plugin.lua", "./lib/config.lua" },  -- add deps that static analysis cannot detect
  exclude = { "./test/test_utils.lua" },                 -- remove false positive deps
})

-- Fully manual mode: disable automatic analysis, specify all dependencies manually
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  depscan = false,
  include = { "./module1.lua", "./module2.lua" },
})

-- Full example with all parameters
local ok, out = luainstaller.bundle({
  entry    = "src/main.lua",
  out      = "build/",
  onefile  = false,
  verbose  = true,
  max_deps = 50,
  include  = { "plugins/extra.lua" },
  exclude  = { "test/mock.lua" },
  depscan  = true,
  icon     = "./logo.ico",    -- Windows only
})
if ok then print("Bundle succeeded: " .. out)
else      print("Bundle failed: " .. out) end
```

---

#### `analyze` — Dependency Analysis

**Function signature**

```lua
local ok, deps = luainstaller.analyze(entry, opts)
```

Return values: when `ok=true`, `deps` is an array of dependency path strings (`string[]`); when `ok=false`, `deps` is an error message string.

**Parameters**

| Parameter       | Type    | Default  | Description                                                                           |
|-----------------|---------|----------|---------------------------------------------------------------------------------------|
| `entry`         | string  | required | Entry script path                                                                     |
| `opts.max_deps` | number  | `36`     | Maximum number of dependencies                                                        |
| `opts.depscan`  | boolean | `true`   | Whether to enable automatic dependency analysis (`false` disables automatic scanning) |

**Examples**

```lua
-- Basic usage
local ok, deps = luainstaller.analyze("main.lua")
if ok then
  print("Found " .. #deps .. " dependencies")
  for i, dep in ipairs(deps) do
    print(string.format("  %d) %s", i, dep))
  end
else
  print("Analysis failed: " .. deps)
end

-- Full example with all parameters
local ok, deps = luainstaller.analyze("src/main.lua", {
  max_deps = 50,
  depscan  = true,
})
if ok then
  for i, dep in ipairs(deps) do
    print(string.format("  %d) %s", i, dep))
  end
else
  print("Analysis failed: " .. deps)
end
```

> `analyze` only performs dependency analysis and produces no bundling artifacts. It is suitable for pre-checking whether all dependencies are complete and whether any false positives exist before performing the actual bundle.

---

#### `version` — Get Version

```lua
print("luainstaller version: " .. luainstaller.version())
```

---

## How It Works

The workflow of `luainstaller` can be summarized as: **analyze entry script → collect dependencies → build executable → optionally wrap into a single file**.

When `bundle` is executed, `luainstaller` first performs **static dependency analysis** starting from the entry `.lua` file. It scans the source code for common reference patterns such as `require(...)`, recursively finding all Lua files the project depends on. For cases that static analysis cannot fully cover — such as runtime module name concatenation or conditional module loading — dependencies can be supplemented manually via `--include` and false positives can be removed via `--exclude`.

Once the dependency set is determined, `luainstaller` organizes the entry script and the collected Lua code into a bundle set ready for packaging. For pure Lua projects, this step typically only involves the scripts themselves; for projects containing non-pure-Lua content, additional files must also be handled to ensure the final artifact runs correctly on the **same system environment**.

In the executable generation stage, `luainstaller` uses **`luastatic`** as its core backend, paired with a **GCC-compatible toolchain** to complete compilation and linking. The fundamental approach is not to rely on a pre-installed `lua` environment on the target machine to run scripts, but instead to construct the Lua program and related content into a directly distributable program. On Windows, if `--icon` is specified, `windres` is additionally used to compile icon resources into the final executable.

By default, `luainstaller` uses **directory output mode**: it generates an output directory containing the executable and required files. When `--onefile` is enabled, it further performs **single-file packaging** on top of this, bundling all runtime content into a single standalone executable for easier distribution and deployment.

Overall, `luainstaller`'s technology stack remains fairly straightforward: the Lua side handles the CLI, dependency analysis, and bundling process control; `luastatic` handles the static integration of the Lua program; the GCC-compatible toolchain handles final compilation and linking; and `windres` handles icon and other resource embedding on Windows.

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
[Organize bundle content]
     |
     v
[luastatic + GCC compile & link]
     |
     +----------------------+
     |                      |
     v                      v
[Directory mode output]   [--onefile single-file packaging]
     |                      |
     +----------+-----------+
                |
                v
      [Distributable executable]
```
