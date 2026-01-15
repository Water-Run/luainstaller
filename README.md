# luainstaller

`luainstaller` is a tool for packaging `.lua` files into `.exe` executables, supporting both Windows and Linux platforms. It provides pre-compiled binaries and works out-of-the-box on devices with a `lua` environment.

It uses [luastatic](https://github.com/ers35/luastatic) as the packaging engine and [Warp](https://github.com/warpdotdev/Warp) for bundling.

Open-sourced on [GitHub](https://github.com/Water-Run/luainstaller), following the ISC license.

> luainstaller was previously provided as a Python library, but it has now been separated into an independent command-line tool

## Installation

There are two ways to install: as a Lua library or by downloading the binary directly:

```bash
luarocks install luainstaller
```

Or [download the binary](https://github.com/Water-Run/luainstaller/releases).

Regardless of which installation method you use, using it as a command-line tool is consistent. However, only installation via `luarocks` allows it to be used as a Lua library within Lua scripts.

## Usage

### Using as a Command-Line Tool

The CLI tool name is `luainstaller`.

- Get help

```bash
luainstaller help
```

```plaintext
luainstaller v0.1.0

installed via luarocks
https://github.com/Water-Run/luainstaller

help:
  ...
```

> If you downloaded the pre-compiled binary, it will display as `installed via binary(windows)`/`installed via binary(linux)`

> On Linux, you can also use `man luainstaller` to view help

- Execute packaging

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
success.
<path_to_lua_entry_file> => <path_to_bundled_exe_file>
```

`luainstaller` will start from the entry `.lua` script, perform dependency analysis (static), and package all dependencies into an executable file (by default, same name in the same directory).

Optional parameters:

|Parameter|Description|Example|
|---|---|---|
|`--output <path_to_bundled_exe_file>`|Specify output path|`luainstaller bundle main.lua --output ../output.exe`|
|`--verbose`|Display detailed information|`luainstaller bundle main.lua --verbose`|
|`--no-wrap`|Don't use Warp to package into a single `.exe`|`luainstaller bundle main.lua --no-wrap`|
|`--max-dependencies <amount>`|Maximum number of dependencies (default 36)|`luainstaller bundle main.lua --max-dependencies 10`|
|`--manual-add-require <require_script_path>`|Manually add dependencies (e.g., for dynamic imports where dependency analysis fails)|`luainstaller bundle main.lua --manual-add-require ./require.lua --manual-add-require ./require2.lua`|
|`--manual-exclude <require_script_path>`|Manually exclude dependencies (e.g., for scenarios where dependency analysis forces imports like `pcall`)|`luainstaller bundle main.lua --manual-exclude ./require.lua --manual-exclude ./require2.lua`|
|`--disable-dependency-analysis`|Disable dependency analysis; all dependencies must be manually added|`luainstaller bundle main.lua --disable-dependency-analysis`|

### Calling from Lua Scripts

Basic usage is consistent.

```lua
local luainstaller = require("luainstaller")

-- Simplest packaging: automatically analyze dependencies and generate exe with same name
local success, result = luainstaller.bundle({
    entry = "main.lua"  -- Entry script path (required)
})

-- Specify output path
local success, result = luainstaller.bundle({
    entry = "main.lua",
    output = "../dist/myapp.exe"  -- Output executable path (optional, defaults to same directory/name)
})

-- Display detailed packaging information
local success, result = luainstaller.bundle({
    entry = "main.lua",
    verbose = true  -- Show detailed dependency analysis and compilation process (optional, default false)
})

-- Manually add dependencies (for dynamic require cases that automatic analysis can't detect)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    manual_add_require = {  -- List of manually added dependencies (optional, default empty table)
        "./lib/plugin.lua",
        "./lib/config.lua"
    }
})

-- Manually exclude dependencies (to exclude false-positive dependencies)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    manual_exclude = {  -- List of manually excluded dependencies (optional, default empty table)
        "./test/test_utils.lua"
    }
})

-- Increase dependency limit
local success, result = luainstaller.bundle({
    entry = "main.lua",
    max_dependencies = 100  -- Maximum dependency analysis count (optional, default 36)
})

-- Disable Warp packaging (generate multiple files instead of single exe)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    no_wrap = true  -- Disable Warp single-file packaging (optional, default false)
})

-- Fully manual mode (disable automatic dependency analysis)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    disable_dependency_analysis = true,  -- Disable dependency analysis (optional, default false)
    manual_add_require = {  -- Must manually specify all dependencies in this case
        "./module1.lua",
        "./module2.lua"
    }
})

-- Complete example using all parameters
local success, result = luainstaller.bundle({
    entry = "src/main.lua",              -- Entry script
    output = "build/myapp.exe",          -- Output path
    verbose = true,                      -- Show detailed information
    max_dependencies = 50,               -- Maximum dependencies
    manual_add_require = {               -- Manually add dependencies
        "plugins/extra.lua"
    },
    manual_exclude = {                   -- Manually exclude dependencies
        "test/mock.lua"
    },
    no_wrap = false,                     -- Use Warp packaging
    disable_dependency_analysis = false  -- Enable dependency analysis
})

-- Check packaging result
if success then
    print("Packaging successful: " .. result)  -- result is the output file path
else
    print("Packaging failed: " .. result)  -- result is the error message
end

-- Only analyze dependencies without packaging
local success, deps = luainstaller.analyze_dependencies(
    "main.lua",  -- Entry script
    50           -- Maximum dependencies (optional, default 36)
)
if success then
    print("Found " .. #deps .. " dependencies")
    for i, dep in ipairs(deps) do
        print(i .. ". " .. dep)
    end
end

-- Get version information
print("luainstaller version: " .. luainstaller.version())
```
