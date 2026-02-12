# luainstaller

`luainstaller` is a tool that packages Lua projects into **distributable executables** for **Windows** and **Linux**. It is open-sourced on [GitHub](https://github.com/Water-Run/luainstaller) and licensed under the **LGPL**.
`luainstaller` provides dependency analysis and single-file bundling, and can package non-pure-Lua content inside the wrapper program.

> `luainstaller` was previously provided as a Python library; older versions could only bundle pure Lua scripts.

## Installation

Install via `luarocks`:

```bash
luarocks install luainstaller
````

## Usage

`luainstaller` can be used as a CLI tool or invoked from Lua scripts.

### Using as a Command-Line Tool

CLI command name: `luainstaller`

* Show help

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

> On Linux, you can also use `man luainstaller` to view the manual (if the manpage is installed).

#### Bundling (bundle)

The most commonly used command is `bundle`.

* Default: outputs a directory

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
success.
<entry.lua> => <output_dir>/
```

By default, `luainstaller` performs **static dependency analysis** starting from the entry `.lua` file and outputs all required runtime files into a directory.

* Single-file mode: outputs a single file only when `--onefile` is specified

```bash
luainstaller bundle <path_to_lua_entry_file> --onefile
```

```plaintext
success.
<entry.lua> => <output_file>
```

`--onefile` further wraps the directory bundle output into a **single executable file**.

#### Optional Parameters

| Option             | Description                                                                                                | Example                                                                                                        |
|--------------------|------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `-o, --out <path>` | Output path: directory in default mode; file when `--onefile` is enabled                                   | `luainstaller bundle main.lua --out ../dist/` / `luainstaller bundle main.lua --onefile --out ../dist/app.exe` |
| `--onefile`        | Generate a single-file executable (disabled by default; default output is a directory)                     | `luainstaller bundle main.lua --onefile`                                                                       |
| `-v, --verbose`    | Print more detailed analysis and bundling logs                                                             | `luainstaller bundle main.lua --verbose`                                                                       |
| `--max-deps <n>`   | Maximum number of dependencies (default: 36)                                                               | `luainstaller bundle main.lua --max-deps 100`                                                                  |
| `--include <path>` | Manually include dependencies (repeatable; for cases static analysis can’t detect, e.g. dynamic `require`) | `luainstaller bundle main.lua --include ./require.lua --include ./plugin.lua`                                  |
| `--exclude <path>` | Manually exclude dependencies (repeatable; to remove false positives such as `pcall(require, ...)`)        | `luainstaller bundle main.lua --exclude ./test_utils.lua`                                                      |
| `--no-depscan`     | Disable dependency scanning (enter “fully manual mode”; you must specify all dependencies via `--include`) | `luainstaller bundle main.lua --no-depscan --include ./a.lua --include ./b.lua`                                |

#### Analyze Dependencies Only (analyze)

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

### Calling from Lua Scripts

The Lua API uses the same parameter semantics as the CLI. Dependency scanning is enabled by default; set `depscan = false` to disable it.

```lua
local luainstaller = require("luainstaller")

-- Simplest bundling: outputs a directory by default (automatic dependency scanning)
local ok, out = luainstaller.bundle({
  entry = "main.lua",
})
-- ok=true  -> out is the output directory path
-- ok=false -> out is an error message

-- Specify output directory
local ok, out = luainstaller.bundle({
  entry = "main.lua",
  out   = "../dist/",     -- directory mode: out is a directory
})

-- Single-file mode: outputs a single file only when onefile=true
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  onefile = true,
  out     = "../dist/app.exe",  -- single-file mode: out is a file
})

-- Verbose logs
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  verbose = true,
})

-- Manually include dependencies (for dynamic require, etc. that cannot be detected automatically)
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  include  = {
    "./lib/plugin.lua",
    "./lib/config.lua",
  },
})

-- Manually exclude dependencies (to remove false positives)
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  exclude  = {
    "./test/test_utils.lua",
  },
})

-- Increase dependency limit
local ok, out = luainstaller.bundle({
  entry     = "main.lua",
  max_deps  = 100,     -- default: 36
})

-- Fully manual mode: disable dependency scanning (you must include all dependencies)
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  depscan  = false,    -- equivalent to CLI --no-depscan
  include  = {
    "./module1.lua",
    "./module2.lua",
  },
})

-- Full example with all parameters
local ok, out = luainstaller.bundle({
  entry     = "src/main.lua",        -- entry script
  out       = "build/",              -- output dir in directory mode; output file when onefile=true
  onefile   = false,                 -- default: false (outputs a directory)
  verbose   = true,                  -- verbose output
  max_deps  = 50,                    -- max number of dependencies
  include   = { "plugins/extra.lua" },
  exclude   = { "test/mock.lua" },
  depscan   = true,                  -- default: true
})

if ok then
  print("Bundle succeeded: " .. out)
else
  print("Bundle failed: " .. out)
end

-- Analyze dependencies only (no bundling)
local ok, deps = luainstaller.analyze("main.lua", {
  max_deps = 50,      -- optional, default: 36
  depscan  = true,    -- optional, default: true (if false, no automatic analysis is performed)
})
if ok then
  print("Found " .. #deps .. " dependencies")
  for i, dep in ipairs(deps) do
    print(i .. ". " .. dep)
  end
else
  print("Analysis failed: " .. deps)
end

-- Get version
print("luainstaller version: " .. luainstaller.version())
```

#### Lua API Options

Options for `luainstaller.bundle(opts)`:

* `entry` (string, required): entry script path
* `out` (string, optional): output path

  * `onefile=false` (default): output directory path
  * `onefile=true`: output file path
* `onefile` (boolean, optional, default `false`): single-file mode switch
* `verbose` (boolean, optional, default `false`): verbose logging
* `max_deps` (number, optional, default `36`): maximum number of dependencies
* `include` (string[], optional, default `{}`): manually include dependencies (repeatable)
* `exclude` (string[], optional, default `{}`): manually exclude dependencies (repeatable)
* `depscan` (boolean, optional, default `true`): enable dependency scanning (`false` is equivalent to CLI `--no-depscan`)

```
