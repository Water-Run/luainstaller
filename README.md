# `luainstaller`: Python Library for Packaging `.lua` into Binaries with Dependency Analysis

***[中文](./README-zh.md)***

`luainstaller` is an [open-source](https://github.com/Water-Run/luainstaller) **Python library** that follows the `LGPL` license and encapsulates the capability to **package `.lua` files into executables**.

`luainstaller` can be used:

- ***As a command-line tool***
- ***As a graphical tool***
- ***As a library imported into your projects***

## Installation

`luainstaller` is published on [PyPI](https://pypi.org/project/luainstaller/), install it using `pip`:

```bash
pip install luainstaller
```

After installation, run in the terminal:

```bash
luainstaller
```

You should get the output:

```plaintext
luainstaller by WaterRun. Version 1.0.
Visit: https://github.com/Water-Run/luainstaller :-)
```

Before using, you also need to configure the `luastatic` environment, including:

- lua: [Lua official website](https://www.lua.org/), including the package manager `luarocks`
- luastatic: `luarocks install luastatic`
- gcc: usually comes with `linux`, on `windows` refer to: [MinGW](https://github.com/niXman/mingw-builds-binaries)

And ensure these are configured in your environment variables.

## Getting Started Tutorial

The workflow of `luainstaller` is very simple:

1. Analyze the current environment and obtain dynamic libraries
2. Scan the entry script recursively to build dependency analysis (if automatic dependency analysis is not disabled)
3. Merge manually configured dependency scripts to generate the dependency list
4. Call `luastatic` to compile according to the dependency list and output to the specified directory

As shown:

```plaintext
                    {Environment Analysis}
                         |
                  test.lua <Entry Script>
                         |
                 {Automatic Dependency Analysis}
                         |
        ┌───────────────────────────────────┐
        |                                   |
        |        ┌──> require("utils/log")  |
        |        |          │               |
        |        |     utils/log.lua        |
        |        |          │               |
        |        |     require("utils/time")|
        |        |          │               |
        |        |     utils/time.lua       |
        |        |                          |
        |        |                          |
        |        └──> require("core/init")  |
        |                   │               |
        |            core/init.lua          |
        |            core/config.lua        |
        |            core/db.lua            |
        |                                   |
        └───────────────────────────────────┘
                         |
               (Manual Dependency Configuration)
                         |
                  extra/plugin.lua
                         |
                         ↓
                    <Dependency List>
    -------------------------------------------------
    utils/log.lua
    utils/time.lua
    core/init.lua
    core/config.lua
    core/db.lua
    extra/plugin.lua
    -------------------------------------------------
                         ↓
             {Invoke luastatic Compile Command}

luastatic test.lua utils/log.lua utils/time.lua core/init.lua core/config.lua core/db.lua extra/plugin.lua /usr/lib64/liblua.so -o test.exe
```

### About Automatic Dependency Analysis

`luainstaller` has limited automatic dependency analysis capability. The engine matches `require` statements in the following forms, performs recursive searching, and obtains the dependency list:

```lua
require '{pkg_name}'
require "{pkg_name}"
require('pkg_name')
require("pkg_name")
require([[pkg_name]])
```

> Imports using `pcall` are also treated as equivalent to `require` imports

Other forms will cause errors, including dynamic dependencies. In such cases, you should disable automatic dependency analysis and manually add the required dependencies.

### Using as a Graphical Tool

The simplest way to use it is through the `GUI`.
`luainstaller` provides a graphical interface implemented with `Tkinter`. After installation, enter in the terminal:

```bash
luainstaller-gui
```

This will launch it.

> The GUI interface only includes basic features

### Using as a Command-Line Tool

The primary way to use `luainstaller` is as a command-line tool. Simply enter in the terminal:

```bash
luainstaller
```

> Or `luainstaller-cli`, both are equivalent

#### Command Set

##### Get Help

```bash
luainstaller help
```

This will output usage help.

##### Get Logs

```bash
luainstaller logs [-limit <limit number>] [-asc]
```

This will output the operation logs stored by luainstaller.

*Parameters:*

- limit: The number of outputs to limit, a positive integer
- asc: In chronological order (default is reverse order)

> The logging system uses [SimpSave](https://github.com/Water-Run/SimpSave)

##### Dependency Analysis

```bash
luainstaller analyze <entry script> [-max <max dependencies>] [--detail]
```

This will perform dependency analysis and output the analysis list.

*Parameters:*

- max: Maximum dependency tree limit, a positive integer
- detail: Detailed runtime output

> By default, analyzes up to 36 dependencies

##### Execute Compilation

```bash
luainstaller build <entry script> [-require <dependent .lua scripts>] [-max <max dependencies>] [-output <output binary path>] [--manual] [--detail]
```

*Parameters:*

- entry script: The corresponding entry script, starting point of dependency analysis
- require: Dependent scripts, if the corresponding script has been automatically analyzed by the analysis engine, it will be skipped. Multiple scripts separated by commas
- max: Maximum dependency tree limit, a positive integer. By default, analyzes up to 36
- output: Specifies the output binary path, defaults to an executable file with the same name as the .lua in the current directory, automatically adding .exe suffix on Windows platform
- manual: Do not perform dependency analysis, directly compile the entry script unless forcibly specified using -require
- detail: Detailed runtime output

*Examples:*

```bash
luainstaller hello_world.lua
```

Compiles hello_world.lua into an executable hello_world (Linux) or hello_world.exe (Windows) in the same directory.

```bash
luainstaller a.lua -require b.lua,c.lua --manual
```

Packages a.lua together with dependencies b.lua and c.lua into a binary without automatic dependency analysis. The behavior is completely consistent with using luastatic directly.

```bash
luainstaller test.lua -max 100 -output ../myProgram --detail
```

Analyzes test.lua with up to 100 dependency items, packages it into the myProgram binary in the parent directory, and displays detailed compilation information.

## Using as a Library

`luainstaller` can also be imported as a library into your scripts:

```python
import luainstaller
```

And provides a functional API.

## API Reference

### `get_logs()`

Get logs

```python
def get_logs(limit: int | None = None,
             _range: range | None = None,
             desc: bool = True) -> list[dict[str, Any]]:
    r"""
    Returns luainstaller logs.

    :param limit: Return number limit, None means no limit
    :param _range: Return range limit, None means no limit
    :param desc: Whether to return in reverse order
    :return list[dict[str, Any]]: List of log dictionaries
    """
```

Example:

```python
import luainstaller

log_1: dict = luainstaller.get_logs()  # Get all logs in reverse order
log_2: dict = luainstaller.get_logs(limit=100, _range=range(128, 256), desc=False)  # Get up to 100 logs in order, within the range of 128 to 256
```

### `analyze()`

Execute dependency analysis (corresponds to CLI's `luainstaller analyze`)

```python
def analyze(entry: str,
            max_deps: int = 36) -> list[str]:
    r"""
    Execute dependency analysis on the entry script.

    :param entry: Entry script path
    :param max_deps: Maximum recursive dependency count, default 36
    :return list[str]: List of dependency script paths obtained from analysis
    """
```

Example:

```python
import luainstaller

deps_1: list = luainstaller.analyze("main.lua")  # Dependency analysis, analyzes up to 36 dependencies by default
deps_2: list = luainstaller.analyze("main.lua", max_deps=112)  # Execute dependency analysis, modify maximum dependency analysis count to 112
```

### `build()`

Execute compilation (corresponds to CLI's `luainstaller build`)

```python
def build(entry: str,
          requires: list[str] | None = None,
          max_deps: int = 36,
          output: str | None = None,
          manual: bool = False) -> str:
    r"""
    Execute script compilation.

    :param entry: Entry script
    :param requires: Manually specify dependency list; if empty, rely only on automatic analysis
    :param max_deps: Maximum dependency tree analysis count
    :param output: Output binary path, None uses default rule
    :param manual: Disable automatic dependency analysis
    :return str: Path of the generated executable file
    """
```

Example:

```python
import luainstaller

# Simplest build method, automatically analyzes dependencies and generates an executable with the same name as the script
luainstaller.build("hello.lua")

# Manual mode: Disable automatic dependency analysis, compile only with scripts specified in requires
luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)
```
