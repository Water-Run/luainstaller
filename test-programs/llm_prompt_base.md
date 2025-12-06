这是我的项目架构:  

```bash
├── cli.py
├── dependency_analyzer.py
├── engine.py
├── exceptions.py
├── gui.py
├── __init__.py
├── logger.py
```

对应项目文档:  

```markdown
# `luainstaller`: Python库, 将`.lua`打包二进制, 包括依赖分析能力  

***[English](./README.md)***  

`luainstaller`是一个[开源](https://github.com/Water-Run/luainstaller)的**Python库**, 遵循`LGPL`协议, 封装了**将`.lua`打包为可执行文件**的能力.  

`luainstaller`可以:  

- ***以命令行工具使用***  
- ***以图形化工具使用***  
- ***作为库引入到你的项目中***  

## 安装  

`luainstaller`发布在[pypi](https://pypi.org/project/luainstaller/)上, 使用`pip`进行安装:  

```bash
pip install luainstaller
```

安装完毕后, 在终端中运行:  

```bash
luainstaller
```

获取输出:  

```plaintext
luainstaller by WaterRun. Version 1.0.
Visit: https://github.com/Water-Run/luainstaller :-)
```

在开始使用前, 还需要配置`luastatic`环境, 包括:  

- lua: [Lua官网](https://www.lua.org/), 包括包管理器`luarocks`  
- luastatic: `luarocks install luastatic`  
- gcc: `linux`上一般自带, `windows`上参考: [MinGW](https://github.com/niXman/mingw-builds-binaries)

并确保这些名称配置在环境变量中.  

## 上手教程  

`luainstaller`的工作流很简洁:  

1. 分析当前的环境, 获取动态库  
2. 对入口脚本扫描, 递归, 构建依赖分析(如果自动依赖分析未被禁用)  
3. 合并手动配置的依赖脚本, 生成依赖列表  
4. 根据依赖列表调用`luastatic`进行编译, 输出到指定目录  

如图示:  

```plaintext
                    {环境分析}
                         |
                  test.lua <入口脚本>
                         |
                 {自动依赖分析}
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
               (手动配置依赖)
                         |
                  extra/plugin.lua
                         |
                         ↓
                    <依赖清单>
    -------------------------------------------------
    utils/log.lua
    utils/time.lua
    core/init.lua
    core/config.lua
    core/db.lua
    extra/plugin.lua
    -------------------------------------------------
                         ↓
             {调用 luastatic 编译命令}

luastatic test.lua utils/log.lua utils/time.lua core/init.lua core/config.lua core/db.lua extra/plugin.lua /usr/lib64/liblua.so -o test.exe
```

### 关于自动依赖分析  

`luainstaller`具备有限的自动依赖分析能力, 引擎会匹配以下形式的`requrie`语句, 进行递归查找, 获取依赖列表:  

```lua
require '{pkg_name}'
require "{pkg_name}"
require('pkg_name')
require("pkg_name")
require([[pkg_name]])
```

> 使用`pcall`的引入也会被视为和`require`等效导入  

此外的形式将导致报错, 包括动态依赖等. 此时, 应当禁用自动依赖分析, 改用手动添加所需依赖.  

### 作为图形化工具使用  

最简单的使用方式莫过于`GUI`了.  
`luainstaller`提供一个由`Tkinter`实现的图形界面. 在完成安装后, 在终端中输入:  

```bash
luainstaller-gui
```

即可启动.  

> GUI界面仅包含基础功能  

### 作为命令行工具使用  

`luainstaller`最主要的使用方式是作为命令行工具. 在终端中输入:  

```bash
luainstaller
```

即可.  

> 或`luainstaller-cli`, 二者是等效的  

#### 指令集  

##### 获取帮助  

```bash
luainstaller help
```

这将输出使用帮助.

##### 获取日志  

```bash
luainstaller logs [-limit 限制数] [-asc]
```

这将输出luainstaller存储的操作日志.

*参数:*

- limit: 限制的输出数目, 大于0的整数
- asc: 按时间顺序(默认倒序)

> 日志系统使用[SimpSave](https://github.com/Water-Run/SimpSave)  

##### 依赖分析  

```bash
luainstaller analyze 入口脚本 [-max 最大依赖数] [--detail]
```

这将执行依赖分析, 输出分析列表.

*参数:*  

- max: 限制的最大依赖树, 大于0的整数
- detail: 详细的运行输出

> 默认情况下, 分析至多36个依赖

##### 执行编译  

```bash
luainstaller build 入口脚本 [-require <依赖的.lua脚本>] [-max 最大依赖数] [-output <输出的二进制路径>] [--manual] [--detail]
```

*参数:*

- 入口脚本: 对应的入口脚本, 依赖分析的起点
- require: 依赖的脚本, 如果对应脚本已由分析引擎自动分析到, 将跳过. 多个使用,隔开
- max: 限制的最大依赖树, 大于0的整数. 默认情况下, 至多分析36个
- output: 指定输出的二进制路径, 默认为在当前目录下和.lua同名的可执行文件, 在Windows平台上自动添加.exe后缀
- manual: 不进行依赖分析, 直接编译入口脚本, 除非使用-require强制指定
- detail: 详细的运行输出

*示例:*

```bash
luainstaller hello_world.lua
```

将hello_world.lua编译为同目录下的可执行文件hello_world(Linux)或hello_world.exe(Linux).  

```bash
luainstaller a.lua -require b.lua, c.lua --manual
```

将a.lua和依赖b.lua, c.lua一同打包为二进制, 不进行自动依赖分析, 此时行为和直接使用luastatic完全一致.

```bash
luainstaller test.lua -max 100 -output ../myProgram --detail
```

将test.lua设置至多分析至100个依赖项, 打包至上级目录下的myProgram二进制中, 并显示详尽的编译信息.

## 作为库使用  

`luainstaller`也可以作为库导入你的脚本中:  

```python
import luainstaller
```

并提供函数式的API.  

## API参考  

### `get_logs()`

获取日志  

```python
def get_logs(limit: int | None = None,
             _range: range | None = None,
             desc: bool = True) -> list[dict[str, Any]]:
    r"""
    返回luainstaller日志.
    :param limit: 返回数限制, None表示不限制
    :param _range: 返回范围限制, None表示不限制
    :param desc: 是否倒序返回
    :return list[dict[str, Any]]: 日志字典组成的列表
    """
```

示例:

```python
import luainstaller

log_1: dict = luainstaller.get_logs() # 以倒序获取全部日志
log_2: dict = luainstaller.get_logs(limit = 100, _range = range(128, 256), desc=False) # 以顺序获取最多一百条, 范围在128到256之间的日志
```

### `analyze()`

执行依赖分析（对应 CLI 的 `luainstaller analyze`）

```python
def analyze(entry: str,
            max_deps: int = 36) -> list[str]:
    r"""
    对入口脚本执行依赖分析.

    :param entry: 入口脚本路径
    :param max_deps: 最大递归依赖数, 默认36
    :return list[str]: 分析得到的依赖脚本路径列表
    """
```

示例:

```python
import luainstaller

deps_1: list = luainstaller.analyze("main.lua") # 依赖分析, 默认最多分析36个依赖
deps_2: list = luainstaller.analyze("main.lua", max_deps=112) # 执行依赖分析, 将最大依赖分析数量修改为112
```

### `build()`

执行编译（对应 CLI 的 `luainstaller build`）

```python
def build(entry: str,
          requires: list[str] | None = None,
          max_deps: int = 36,
          output: str | None = None,
          manual: bool = False) -> str:
    r"""
    执行脚本编译.

    :param entry: 入口脚本
    :param requires: 手动指定依赖列表; 若为空则仅依赖自动分析
    :param max_deps: 最大依赖树分析数
    :param output: 输出二进制路径, None 使用默认规则
    :param manual: 禁用自动依赖分析
    :return str: 生成的可执行文件路径
    """
```

示例:

```python
import luainstaller

# 最简单的构建方式, 自动分析依赖并生成与脚本同名的可执行文件
luainstaller.build("hello.lua")

# 手动模式: 禁用自动依赖分析, 仅使用 requires 指定的依赖脚本进行编译
luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)
```

```

依次代码:  

`__init__.py`:  

```python
"""
luainstaller - Python library for packaging Lua scripts into standalone executables.
https://github.com/Water-Run/luainstaller

This package provides tools for:
- Dependency analysis of Lua scripts
- Compilation to standalone executables using luastatic
- Command-line and graphical interfaces

:author: WaterRun
:file: __init__.py
:date: 2025-12-05
"""

from pathlib import Path

from .dependency_analyzer import analyze_dependencies
from .engine import compile_lua_script, get_environment_status
from .exceptions import (
    CModuleNotSupportedError,
    CircularDependencyError,
    CompilationError,
    CompilationFailedError,
    CompilerNotFoundError,
    DependencyAnalysisError,
    DependencyLimitExceededError,
    DynamicRequireError,
    LuaInstallerException,
    LuastaticNotFoundError,
    ModuleNotFoundError,
    OutputFileNotFoundError,
    ScriptNotFoundError,
)
from .logger import LogEntry, LogLevel, clear_logs
from .logger import get_logs as _get_logs
from .logger import log_error, log_success


__version__ = "1.0.0"
__author__ = "WaterRun"
__email__ = "linzhangrun49@gmail.com"
__url__ = "https://github.com/Water-Run/luainstallers/tree/main/luainstaller"


__all__ = [
    # Version info
    "__version__",
    "__author__",
    "__email__",
    "__url__",
    # Public API
    "get_logs",
    "clear_logs",
    "analyze",
    "build",
    # Exceptions
    "LuaInstallerException",
    "ScriptNotFoundError",
    "DependencyAnalysisError",
    "CircularDependencyError",
    "DynamicRequireError",
    "DependencyLimitExceededError",
    "ModuleNotFoundError",
    "CModuleNotSupportedError",
    "CompilationError",
    "LuastaticNotFoundError",
    "CompilerNotFoundError",
    "CompilationFailedError",
    "OutputFileNotFoundError",
    # Logger types
    "LogLevel",
    "LogEntry",
]


def get_logs(
    limit: int | None = None,
    level: LogLevel | str | None = None,
    source: str | None = None,
    action: str | None = None,
    descending: bool = True,
) -> list[LogEntry]:
    """
    Retrieve luainstaller operation logs.
    
    Returns log entries from the persistent log store with optional filtering.
    Logs are stored using simpsave and persist across sessions.
    
    :param limit: Maximum number of logs to return. None means no limit.
    :param level: Filter by log level (e.g., 'debug', 'info', 'warning', 'error', 'success').
    :param source: Filter by source (e.g., 'cli', 'gui', 'api').
    :param action: Filter by action (e.g., 'build', 'analyze').
    :param descending: If True, return logs in reverse chronological order (newest first).
    :return: List of log entry dictionaries.
    
    Example::
    
        >>> import luainstaller
        >>> # Get all logs in reverse chronological order
        >>> logs = luainstaller.get_logs()
        >>> # Get up to 100 error logs
        >>> logs = luainstaller.get_logs(limit=100, level="error")
        >>> # Get build logs from the API
        >>> logs = luainstaller.get_logs(source="api", action="build")
    """
    return _get_logs(
        limit=limit,
        level=level,
        source=source,
        action=action,
        descending=descending,
    )


def analyze(entry: str, max_deps: int = 36) -> list[str]:
    """
    Perform dependency analysis on the entry script.
    
    Recursively scans the entry script for require statements and resolves
    all dependencies. Supports standard require patterns including:
    
    - require 'module'
    - require "module"
    - require('module')
    - require("module")
    - require([[module]])
    
    Dynamic require statements (e.g., require(variable)) are not supported
    and will raise DynamicRequireError.
    
    :param entry: Path to the entry Lua script.
    :param max_deps: Maximum number of dependencies to analyze. Default is 36.
                     Increase this for larger projects.
    :return: List of resolved dependency file paths.
    :raises ScriptNotFoundError: If the entry script does not exist.
    :raises CircularDependencyError: If circular dependencies are detected.
    :raises DynamicRequireError: If a dynamic require statement is found.
    :raises DependencyLimitExceededError: If dependency count exceeds max_deps.
    :raises ModuleNotFoundError: If a required module cannot be resolved.
    
    Example::
    
        >>> import luainstaller
        >>> # Analyze dependencies with default limit
        >>> deps = luainstaller.analyze("main.lua")
        >>> print(f"Found {len(deps)} dependencies")
        >>> # Analyze with higher limit for large projects
        >>> deps = luainstaller.analyze("main.lua", max_deps=112)
    """
    return analyze_dependencies(entry, max_dependencies=max_deps)


def build(
    entry: str,
    requires: list[str] | None = None,
    max_deps: int = 36,
    output: str | None = None,
    manual: bool = False
) -> str:
    """
    Compile a Lua script into a standalone executable.
    
    This function performs the following steps:
    
    1. Analyzes dependencies automatically (unless manual mode is enabled)
    2. Merges manually specified dependencies with analyzed ones
    3. Locates the Lua shared library for linking
    4. Invokes luastatic to compile the executable
    
    The generated executable is self-contained and does not require
    Lua or any dependencies to be installed on the target system.
    
    :param entry: Path to the entry Lua script.
    :param requires: Additional dependency scripts to include. These are merged
                     with automatically discovered dependencies. Duplicates are
                     automatically filtered out.
    :param max_deps: Maximum dependency count for automatic analysis. Default is 36.
    :param output: Output executable path. If None, generates an executable with
                   the same name as the entry script in the current directory.
                   On Windows, '.exe' suffix is added automatically.
    :param manual: If True, disables automatic dependency analysis. Only scripts
                   specified in 'requires' will be included.
    :return: Absolute path to the generated executable.
    :raises ScriptNotFoundError: If the entry script or a required script does not exist.
    :raises LuastaticNotFoundError: If luastatic is not installed.
    :raises CompilerNotFoundError: If gcc/clang is not available.
    :raises CompilationFailedError: If luastatic returns a non-zero exit code.
    :raises OutputFileNotFoundError: If the output file was not created.
    
    Example::
    
        >>> import luainstaller
        >>> # Simple build with automatic dependency analysis
        >>> luainstaller.build("hello.lua")
        '/path/to/hello'
        >>> # Build with custom output path
        >>> luainstaller.build("main.lua", output="./bin/myapp")
        '/path/to/bin/myapp'
        >>> # Manual mode: only include explicitly specified dependencies
        >>> luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)
        '/path/to/a'
        >>> # Combine automatic analysis with additional dependencies
        >>> luainstaller.build("app.lua", requires=["plugins/extra.lua"], max_deps=100)
        '/path/to/app'
    """
    dependencies = [] if manual else analyze_dependencies(
        entry, max_dependencies=max_deps)

    if requires:
        dependency_set = {Path(d).resolve() for d in dependencies}

        for req in requires:
            req_path = Path(req)
            if not req_path.exists():
                raise ScriptNotFoundError(req)

            resolved = req_path.resolve()
            if resolved not in dependency_set:
                dependencies.append(str(resolved))
                dependency_set.add(resolved)

    result = compile_lua_script(
        entry,
        dependencies,
        output=output,
        verbose=False
    )

    log_success("api", "build",
                f"Built {Path(entry).name} -> {Path(result).name}")
    return result

```

`cli.py`:  

```python
"""
Command-line interface for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides the CLI functionality for luainstaller,
including commands for dependency analysis, compilation, and log viewing.

:author: WaterRun
:file: cli.py
:date: 2025-12-05
"""

import sys
from pathlib import Path
from typing import NoReturn

from .dependency_analyzer import analyze_dependencies
from .engine import compile_lua_script, print_environment_status
from .exceptions import LuaInstallerException
from .logger import LogLevel, get_logs, log_error, log_success


VERSION = "1.0"
PROJECT_URL = "https://github.com/Water-Run/luainstaller"


HELP_MESSAGE = f"""\
luainstaller - Package Lua scripts into standalone executables

Usage:
    luainstaller                              Show version info
    luainstaller help                         Show this help message
    luainstaller logs [options]               View operation logs
    luainstaller analyze <script> [options]   Analyze dependencies
    luainstaller build <script> [options]     Build executable

Commands:

  help
      Display this help message.

  logs [-limit <n>] [--asc] [-level <level>]
      Display stored operation logs.
      
      Options:
          -limit <n>     Limit the number of logs to display
          --asc           Display in ascending order (default: descending)
          -level <level> Filter by level (debug, info, warning, error, success)

  analyze <entry_script> [-max <n>] [--detail]
      Perform dependency analysis on the entry script.
      
      Options:
          -max <n>     Maximum dependency count (default: 36)
          --detail     Show detailed analysis output

  build <entry_script> [options]
      Compile Lua script into standalone executable.
      
      Options:
          -require <scripts>   Additional dependency scripts (comma-separated)
          -max <n>             Maximum dependency count (default: 36)
          -output <path>       Output executable path
          --manual             Disable automatic dependency analysis
          --detail             Show detailed compilation output

Examples:
    luainstaller build hello.lua
    luainstaller build main.lua -output ./bin/myapp
    luainstaller build app.lua -require utils.lua,config.lua --manual
    luainstaller analyze main.lua -max 100 --detail
    luainstaller logs -limit 20 --asc

Visit: {PROJECT_URL}
"""


class ArgumentParser:
    """Simple argument parser for luainstaller CLI."""
    
    __slots__ = ("args", "pos")
    
    def __init__(self, args: list[str]) -> None:
        """
        Initialize the argument parser.
        
        :param args: Command-line arguments (excluding program name)
        """
        self.args = args
        self.pos = 0
    
    def has_next(self) -> bool:
        """Check if there are more arguments to parse."""
        return self.pos < len(self.args)
    
    def peek(self) -> str | None:
        """Peek at the next argument without consuming it."""
        return self.args[self.pos] if self.has_next() else None
    
    def consume(self) -> str | None:
        """Consume and return the next argument."""
        if self.has_next():
            arg = self.args[self.pos]
            self.pos += 1
            return arg
        return None
    
    def consume_value(self, option_name: str) -> str:
        """
        Consume the next argument as a value for an option.
        
        :param option_name: Name of the option (for error messages)
        :return: The value
        :raises SystemExit: If no value is provided
        """
        value = self.consume()
        if value is None or value.startswith("-"):
            print_error(f"Option '{option_name}' requires a value")
            sys.exit(1)
        return value


def print_version() -> None:
    """Print version information."""
    print(f"luainstaller by WaterRun. Version {VERSION}.")
    print(f"Visit: {PROJECT_URL} :-)")


def print_help() -> None:
    """Print help message."""
    print(HELP_MESSAGE)


def print_error(message: str) -> None:
    """Print an error message to stderr."""
    print(f"Error: {message}", file=sys.stderr)


def print_success(message: str) -> None:
    """Print a success message."""
    print(f"✓ {message}")


def print_info(message: str) -> None:
    """Print an informational message."""
    print(f"  {message}")


def cmd_logs(parser: ArgumentParser) -> int:
    """Handle the 'logs' command."""
    limit: int | None = None
    ascending = False
    level: str | None = None
    
    while parser.has_next():
        match parser.consume():
            case "-limit":
                limit_str = parser.consume_value("-limit")
                try:
                    limit = int(limit_str)
                    if limit <= 0:
                        print_error("-limit must be a positive integer")
                        return 1
                except ValueError:
                    print_error(f"Invalid limit value: {limit_str}")
                    return 1
            
            case "--asc":
                ascending = True
            
            case "-level":
                level = parser.consume_value("-level")
                if level not in ("debug", "info", "warning", "error", "success"):
                    print_error(f"Invalid level: {level}")
                    return 1
            
            case arg:
                print_error(f"Unknown option for logs: {arg}")
                return 1
    
    logs = get_logs(limit=limit, level=level, descending=not ascending)
    
    if not logs:
        print("No logs found.")
        return 0
    
    print(f"Showing {len(logs)} log(s):")
    print("=" * 60)
    
    for entry in logs:
        timestamp = entry.get("timestamp", "Unknown time")
        log_level = entry.get("level", "info")
        source = entry.get("source", "unknown")
        action = entry.get("action", "unknown")
        message = entry.get("message", "")
        
        symbol = {"success": "✓", "error": "✗", "warning": "⚠", "debug": "◦"}.get(log_level, "○")
        
        print(f"[{timestamp}] {symbol} [{source}:{action}] {message}")
        
        if details := entry.get("details"):
            for key, value in details.items():
                print(f"    {key}: {value}")
        
        print("-" * 60)
    
    return 0


def cmd_analyze(parser: ArgumentParser) -> int:
    """Handle the 'analyze' command."""
    entry_script = parser.consume()
    if entry_script is None or entry_script.startswith("-"):
        print_error("analyze command requires an entry script")
        print_info("Usage: luainstaller analyze <script> [-max <n>] [--detail]")
        return 1
    
    max_deps = 36
    detail = False
    
    while parser.has_next():
        match parser.consume():
            case "-max":
                max_str = parser.consume_value("-max")
                try:
                    max_deps = int(max_str)
                    if max_deps <= 0:
                        print_error("-max must be a positive integer")
                        return 1
                except ValueError:
                    print_error(f"Invalid max value: {max_str}")
                    return 1
            
            case "--detail":
                detail = True
            
            case arg:
                print_error(f"Unknown option for analyze: {arg}")
                return 1
    
    entry_path = Path(entry_script)
    if not entry_path.exists():
        print_error(f"Script not found: {entry_script}")
        return 1
    
    if entry_path.suffix != ".lua":
        print_error(f"Entry script must be a .lua file: {entry_script}")
        return 1
    
    try:
        if detail:
            print(f"Analyzing dependencies for: {entry_path.resolve()}")
            print(f"Maximum dependencies: {max_deps}")
            print("=" * 60)
        
        dependencies = analyze_dependencies(str(entry_path), max_dependencies=max_deps)
        
        print(f"Dependencies for {entry_path.name}:")
        
        if not dependencies:
            print("  (no dependencies)")
        else:
            for i, dep_path in enumerate(dependencies, 1):
                dep_name = Path(dep_path).name
                if detail:
                    print(f"  {i}. {dep_name}")
                    print(f"     Path: {dep_path}")
                else:
                    print(f"  {i}. {dep_name}")
        
        print(f"\nTotal: {len(dependencies)} dependency(ies)")
        
        log_success("cli", "analyze", f"Analyzed {entry_path.name}: {len(dependencies)} deps")
        return 0
    
    except LuaInstallerException as e:
        print_error(str(e))
        log_error("cli", "analyze", f"Failed: {e.message}")
        return 1
    
    except Exception as e:
        print_error(f"Unexpected error during analysis: {e}")
        log_error("cli", "analyze", f"Unexpected error: {e}")
        return 1


def cmd_build(parser: ArgumentParser) -> int:
    """Handle the 'build' command."""
    entry_script = parser.consume()
    if entry_script is None or entry_script.startswith("-"):
        print_error("build command requires an entry script")
        print_info("Usage: luainstaller build <script> [options]")
        return 1
    
    requires: list[str] = []
    max_deps = 36
    output: str | None = None
    manual = False
    detail = False
    
    while parser.has_next():
        match parser.consume():
            case "-require":
                require_str = parser.consume_value("-require")
                for req in require_str.split(","):
                    if req := req.strip():
                        requires.append(req)
            
            case "-max":
                max_str = parser.consume_value("-max")
                try:
                    max_deps = int(max_str)
                    if max_deps <= 0:
                        print_error("-max must be a positive integer")
                        return 1
                except ValueError:
                    print_error(f"Invalid max value: {max_str}")
                    return 1
            
            case "-output":
                output = parser.consume_value("-output")
            
            case "--manual":
                manual = True
            
            case "--detail":
                detail = True
            
            case arg:
                print_error(f"Unknown option for build: {arg}")
                return 1
    
    entry_path = Path(entry_script)
    if not entry_path.exists():
        print_error(f"Script not found: {entry_script}")
        return 1
    
    if entry_path.suffix != ".lua":
        print_error(f"Entry script must be a .lua file: {entry_script}")
        return 1
    
    try:
        if detail:
            print(f"Building: {entry_path.resolve()}")
            print(f"Manual mode: {'enabled' if manual else 'disabled'}")
            print(f"Maximum dependencies: {max_deps}")
            if output:
                print(f"Output: {output}")
            if requires:
                print(f"Additional requires: {', '.join(requires)}")
            print("=" * 60)
        
        if manual:
            if detail:
                print("Skipping automatic dependency analysis (manual mode)")
            dependencies: list[str] = []
        else:
            if detail:
                print("Analyzing dependencies...")
            dependencies = analyze_dependencies(str(entry_path), max_dependencies=max_deps)
            if detail:
                print(f"Found {len(dependencies)} dependency(ies)")
        
        dependency_set = {Path(d).resolve() for d in dependencies}
        
        for req in requires:
            req_path = Path(req)
            if not req_path.exists():
                print_error(f"Required script not found: {req}")
                return 1
            
            resolved = req_path.resolve()
            if resolved not in dependency_set:
                dependencies.append(str(resolved))
                dependency_set.add(resolved)
                if detail:
                    print(f"Added manual dependency: {req}")
        
        if detail:
            print(f"Total dependencies: {len(dependencies)}")
            print("Compiling...")
        
        output_path = compile_lua_script(
            str(entry_path),
            dependencies,
            output=output,
            verbose=detail
        )
        
        print_success(f"Build successful: {output_path}")
        
        log_success("cli", "build", f"Built {entry_path.name} -> {Path(output_path).name}")
        
        return 0
    
    except LuaInstallerException as e:
        print_error(str(e))
        log_error("cli", "build", f"Failed: {e.message}")
        return 1
    
    except Exception as e:
        print_error(f"Unexpected error during build: {e}")
        log_error("cli", "build", f"Unexpected error: {e}")
        return 1


def cmd_env() -> int:
    """Handle the 'env' command (environment status)."""
    print_environment_status()
    return 0


def main(args: list[str] | None = None) -> int:
    """
    Main entry point for the CLI.
    
    :param args: Command-line arguments (defaults to sys.argv[1:])
    :return: Exit code
    """
    if args is None:
        args = sys.argv[1:]
    
    parser = ArgumentParser(args)
    
    if not parser.has_next():
        print_version()
        return 0
    
    match parser.consume():
        case "help" | "-h" | "--help":
            print_help()
            return 0
        
        case "version" | "-v" | "--version":
            print_version()
            return 0
        
        case "logs":
            return cmd_logs(parser)
        
        case "analyze":
            return cmd_analyze(parser)
        
        case "build":
            return cmd_build(parser)
        
        case "env":
            return cmd_env()
        
        case command if command.endswith(".lua"):
            return cmd_build(ArgumentParser([command] + args[1:]))
        
        case command:
            print_error(f"Unknown command: {command}")
            print_info("Run 'luainstaller help' for usage information")
            return 1


def cli_main() -> NoReturn:
    """CLI entry point that exits with appropriate code."""
    sys.exit(main())


if __name__ == "__main__":
    cli_main()
```

`dependency_analyzer.py`:  

```python
"""
Dependency analysis engine for Lua scripts.
https://github.com/Water-Run/luainstaller

This module provides comprehensive dependency analysis for Lua scripts,
including static require extraction, module path resolution, and dependency
list construction with cycle detection.

:author: WaterRun
:file: dependency_analyzer.py
:date: 2025-12-05
"""

import os
import subprocess
from enum import Enum, auto
from pathlib import Path
from typing import TYPE_CHECKING

from .exceptions import (
    CModuleNotSupportedError,
    CircularDependencyError,
    DependencyLimitExceededError,
    DynamicRequireError,
    ModuleNotFoundError,
    ScriptNotFoundError,
)

if TYPE_CHECKING:
    from collections.abc import Sequence


class LexerState(Enum):
    """Enumeration of lexer states for parsing Lua source code."""
    
    NORMAL = auto()
    IN_STRING_SINGLE = auto()
    IN_STRING_DOUBLE = auto()
    IN_LONG_STRING = auto()
    IN_LINE_COMMENT = auto()
    IN_BLOCK_COMMENT = auto()


class LuaLexer:
    """
    Lightweight Lua lexer focused on extracting static require statements.
    
    This lexer uses a state machine to correctly handle Lua's various string
    and comment formats, ensuring that require statements inside strings or
    comments are not mistakenly extracted.
    
    Supports both direct require calls and pcall-wrapped requires:
        - require('module')
        - require "module"
        - pcall(require, 'module')
        - pcall(require, "module")
    """
    
    __slots__ = ("source", "file_path", "pos", "line", "state", "long_bracket_level")
    
    def __init__(self, source_code: str, file_path: str) -> None:
        """
        Initialize the Lua lexer.
        
        :param source_code: The Lua source code to analyze
        :param file_path: Path to the source file (for error reporting)
        """
        self.source = source_code
        self.file_path = file_path
        self.pos = 0
        self.line = 1
        self.state = LexerState.NORMAL
        self.long_bracket_level = 0
    
    def extract_requires(self) -> list[tuple[str, int]]:
        """Extract all static require statements from the source code."""
        requires: list[tuple[str, int]] = []

        while self.pos < len(self.source):
            char = self._current_char()
            self._update_state(char)

            if self.state == LexerState.NORMAL:
                if self._match_keyword("pcall"):
                    if module_name := self._parse_pcall_require():
                        requires.append((module_name, self.line))
                    continue
                
                if self._match_keyword("require"):
                    if module_name := self._parse_require():
                        requires.append((module_name, self.line))
                    continue
            
            if char == "\n":
                self.line += 1

            self.pos += 1

        return requires

    def _current_char(self) -> str:
        """Get the current character, or empty string if at end."""
        return self.source[self.pos] if self.pos < len(self.source) else ""
    
    def _peek_char(self, offset: int = 1) -> str:
        """Peek ahead at a character without advancing position."""
        peek_pos = self.pos + offset
        return self.source[peek_pos] if peek_pos < len(self.source) else ""
    
    def _match_keyword(self, keyword: str) -> bool:
        """
        Check if the current position matches a keyword.
        
        Must be surrounded by non-identifier characters to avoid matching
        'required' when looking for 'require'.
        """
        if not self.source[self.pos:].startswith(keyword):
            return False
        
        if (prev_pos := self.pos - 1) >= 0:
            prev_char = self.source[prev_pos]
            if prev_char.isalnum() or prev_char in ("_", ".", ":"):
                return False
        
        next_pos = self.pos + len(keyword)
        if next_pos < len(self.source):
            next_char = self.source[next_pos]
            if next_char.isalnum() or next_char == "_":
                return False
        
        return True
    
    def _update_state(self, char: str) -> None:
        """Update the lexer state machine based on current character."""
        match self.state:
            case LexerState.NORMAL:
                if char == "-" and self._peek_char() == "-":
                    if self._peek_char(2) == "[":
                        level = self._count_bracket_level(2)
                        if level >= 0:
                            self.state = LexerState.IN_BLOCK_COMMENT
                            self.long_bracket_level = level
                            return
                    self.state = LexerState.IN_LINE_COMMENT
                elif char == "'":
                    self.state = LexerState.IN_STRING_SINGLE
                elif char == '"':
                    self.state = LexerState.IN_STRING_DOUBLE
                elif char == "[":
                    level = self._count_bracket_level(0)
                    if level >= 0:
                        self.state = LexerState.IN_LONG_STRING
                        self.long_bracket_level = level
            
            case LexerState.IN_STRING_SINGLE:
                if char == "'" and self._is_not_escaped():
                    self.state = LexerState.NORMAL
            
            case LexerState.IN_STRING_DOUBLE:
                if char == '"' and self._is_not_escaped():
                    self.state = LexerState.NORMAL
            
            case LexerState.IN_LONG_STRING:
                if char == "]" and self._check_closing_bracket(self.long_bracket_level):
                    self.state = LexerState.NORMAL
            
            case LexerState.IN_LINE_COMMENT:
                if char == "\n":
                    self.state = LexerState.NORMAL
            
            case LexerState.IN_BLOCK_COMMENT:
                if char == "]" and self._check_closing_bracket(self.long_bracket_level):
                    self.state = LexerState.NORMAL
    
    def _is_not_escaped(self) -> bool:
        """Check if the current character is not escaped by backslash."""
        if self.pos == 0:
            return True
        
        backslash_count = 0
        check_pos = self.pos - 1
        while check_pos >= 0 and self.source[check_pos] == "\\":
            backslash_count += 1
            check_pos -= 1
        
        return backslash_count % 2 == 0
    
    def _count_bracket_level(self, start_offset: int) -> int:
        """
        Count the level of a long bracket [=*[.
        
        :param start_offset: Offset from current position to start of bracket
        :return: Level (number of =), or -1 if not a valid long bracket
        """
        pos = self.pos + start_offset
        if pos >= len(self.source) or self.source[pos] != "[":
            return -1
        
        pos += 1
        level = 0
        
        while pos < len(self.source) and self.source[pos] == "=":
            level += 1
            pos += 1
        
        return level if pos < len(self.source) and self.source[pos] == "[" else -1
    
    def _check_closing_bracket(self, expected_level: int) -> bool:
        """Check if current position starts a closing bracket ]=*] with matching level."""
        if self._current_char() != "]":
            return False
        
        pos = self.pos + 1
        level = 0
        
        while pos < len(self.source) and self.source[pos] == "=":
            level += 1
            pos += 1
        
        return pos < len(self.source) and self.source[pos] == "]" and level == expected_level
    
    def _skip_whitespace(self) -> None:
        """Skip whitespace characters, updating line count for newlines."""
        while self.pos < len(self.source) and self._current_char() in " \t\n\r":
            if self._current_char() == "\n":
                self.line += 1
            self.pos += 1
    
    def _parse_pcall_require(self) -> str | None:
        """
        Parse a pcall(require, 'module') statement and extract the module name.
        
        :return: Module name if valid pcall require, None otherwise
        """
        start_pos = self.pos
        start_line = self.line
        
        self.pos += len("pcall")
        self._skip_whitespace()
        
        if self._current_char() != "(":
            self.pos = start_pos
            return None
        
        self.pos += 1
        self._skip_whitespace()
        
        if not self.source[self.pos:].startswith("require"):
            self.pos = start_pos
            return None
        
        next_after_require = self.pos + len("require")
        if next_after_require < len(self.source):
            next_char = self.source[next_after_require]
            if next_char.isalnum() or next_char == "_":
                self.pos = start_pos
                return None
        
        self.pos += len("require")
        self._skip_whitespace()
        
        if self._current_char() != ",":
            self.pos = start_pos
            return None
        
        self.pos += 1
        self._skip_whitespace()
        
        char = self._current_char()
        
        if char in ('"', "'"):
            module_name = self._extract_string_literal(start_line)
            self._skip_whitespace()
            if self._current_char() == ")":
                self.pos += 1
            return module_name
        
        if char == "[":
            level = self._count_bracket_level(0)
            if level >= 0:
                module_name = self._extract_long_string_literal(level, start_line)
                self._skip_whitespace()
                if self._current_char() == ")":
                    self.pos += 1
                return module_name
        
        self.pos = start_pos
        return None
    
    def _parse_require(self) -> str | None:
        """
        Parse a require statement and extract the module name.
        
        :return: Module name if static, None to skip
        :raises DynamicRequireError: If the require is dynamic
        """
        start_pos = self.pos
        start_line = self.line
        
        self.pos += len("require")
        self._skip_whitespace()
        
        char = self._current_char()
        
        has_paren = False
        if char == "(":
            has_paren = True
            self.pos += 1
            self._skip_whitespace()
            char = self._current_char()
        
        if char in ('"', "'"):
            module_name = self._extract_string_literal(start_line)
            if has_paren:
                self._skip_whitespace()
                if self._current_char() == ")":
                    self.pos += 1
            return module_name
        
        if char == "[":
            level = self._count_bracket_level(0)
            if level >= 0:
                module_name = self._extract_long_string_literal(level, start_line)
                if has_paren:
                    self._skip_whitespace()
                    if self._current_char() == ")":
                        self.pos += 1
                return module_name
        
        end_pos = self.pos
        while end_pos < len(self.source) and self.source[end_pos] not in "\n;":
            end_pos += 1
        
        statement = self.source[start_pos:end_pos].strip()
        raise DynamicRequireError(self.file_path, start_line, statement)
    
    def _extract_string_literal(self, start_line: int) -> str:
        """
        Extract a string literal (single or double quoted).
        
        :param start_line: Line number where require started
        :return: The string content
        :raises DynamicRequireError: If string concatenation is detected
        """
        quote_char = self._current_char()
        self.pos += 1
        
        result: list[str] = []
        
        while self.pos < len(self.source):
            char = self._current_char()
            
            if char == quote_char and self._is_not_escaped():
                self.pos += 1
                module_name = "".join(result)
                self._check_no_concatenation(start_line, module_name)
                return module_name
            
            if char == "\\":
                result.append(char)
                self.pos += 1
                if self.pos < len(self.source):
                    result.append(self._current_char())
            else:
                result.append(char)
            
            self.pos += 1
        
        raise DynamicRequireError(
            self.file_path,
            start_line,
            "Unterminated string in require statement"
        )
    
    def _extract_long_string_literal(self, level: int, start_line: int) -> str:
        """
        Extract a long string literal [[...]].
        
        :param level: The bracket level
        :param start_line: Line number where require started
        :return: The string content
        """
        self.pos += 2 + level
        
        result: list[str] = []
        
        while self.pos < len(self.source):
            if self._current_char() == "]" and self._check_closing_bracket(level):
                self.pos += 2 + level
                module_name = "".join(result)
                self._check_no_concatenation(start_line, module_name)
                return module_name
            
            result.append(self._current_char())
            if self._current_char() == "\n":
                self.line += 1
            self.pos += 1
        
        raise DynamicRequireError(
            self.file_path,
            start_line,
            "Unterminated long string in require statement"
        )
    
    def _check_no_concatenation(self, start_line: int, module_name: str) -> None:
        """
        Check that there's no string concatenation after the string literal.
        
        :param start_line: Line number where require started
        :param module_name: The extracted module name
        :raises DynamicRequireError: If concatenation is detected
        """
        saved_pos = self.pos
        while self.pos < len(self.source) and self._current_char() in " \t\n\r":
            self.pos += 1
        
        if self.source[self.pos:self.pos + 2] == "..":
            raise DynamicRequireError(
                self.file_path,
                start_line,
                f"require('{module_name}' .. ...) - String concatenation not supported"
            )
        
        self.pos = saved_pos


class ModuleResolver:
    """
    Resolves Lua module names to absolute file paths.
    
    This resolver handles dot-separated module names, relative paths,
    LuaRocks package paths, and standard Lua search patterns.
    """
    
    C_EXTENSIONS = frozenset({".so", ".dll", ".dylib"})
    
    BUILTIN_MODULES = frozenset({
        "_G",
        "coroutine",
        "debug",
        "io",
        "math",
        "os",
        "package",
        "string",
        "table",
        "utf8",
    })
    
    __slots__ = ("base_path", "search_paths")
    
    def __init__(self, base_path: Path) -> None:
        """
        Initialize the module resolver.
        
        :param base_path: Base directory for relative module resolution
        """
        self.base_path = base_path.resolve()
        self.search_paths = self._build_search_paths()
    
    def _detect_luarocks(self) -> list[Path]:
        """Detect LuaRocks installation and return module paths."""
        paths: list[Path] = []
        
        try:
            result = subprocess.run(
                ["luarocks", "path", "--lr-path"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False
            )
            
            if result.returncode == 0 and result.stdout.strip():
                raw = result.stdout.strip()
                
                if "=" in raw and os.linesep in raw:
                    raw = raw.split(os.linesep)[-1].strip().strip("'").strip('"')
                
                sep = ";" if os.name == "nt" else ":"
                lua_paths = raw.split(sep)
                
                for lua_path in lua_paths:
                    lua_path = lua_path.strip().strip("'").strip('"')
                    
                    if lua_path.endswith("?.lua"):
                        lua_path = lua_path[:-len("?.lua")]
                    elif lua_path.endswith("?/init.lua"):
                        lua_path = lua_path[:-len("?/init.lua")]
                    
                    lua_path = lua_path.strip()
                    if lua_path:
                        path_obj = Path(lua_path)
                        if path_obj.exists():
                            paths.append(path_obj.resolve())
        
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            ...
        
        return paths
    
    def _build_search_paths(self) -> list[Path]:
        """Build the complete list of module search paths."""
        paths: list[Path] = []
        seen: set[Path] = set()

        def add_path(candidate: Path) -> None:
            try:
                resolved = candidate.resolve()
            except OSError:
                return
            if resolved.exists() and resolved not in seen:
                paths.append(resolved)
                seen.add(resolved)

        def parse_lua_patterns(raw: str) -> list[Path]:
            if not raw:
                return []
            candidates: list[Path] = []
            for chunk in raw.replace("\r", "").split(";"):
                chunk = chunk.strip().strip('"').strip("'")
                if not chunk:
                    continue
                if "?" in chunk:
                    if chunk.endswith("?.lua"):
                        chunk = chunk[:-len("?.lua")]
                    elif chunk.endswith("?/init.lua"):
                        chunk = chunk[:-len("?/init.lua")]
                    else:
                        continue
                if chunk:
                    candidates.append(Path(chunk))
            return candidates

        add_path(self.base_path)

        for local_dir in (
            self.base_path / "lua_modules",
            self.base_path / "lib",
            self.base_path / "src",
        ):
            if local_dir.exists():
                add_path(local_dir)

        if env_lua_path := os.environ.get("LUA_PATH"):
            for candidate in parse_lua_patterns(env_lua_path):
                add_path(candidate)

        try:
            result = subprocess.run(
                ["lua", "-e", "print(package.path)"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                for candidate in parse_lua_patterns(result.stdout.strip()):
                    add_path(candidate)
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            ...

        for luarocks_path in self._detect_luarocks():
            add_path(luarocks_path)

        return paths
    
    def is_builtin_module(self, module_name: str) -> bool:
        """
        Check if a module name is a Lua builtin module.
        
        :param module_name: The module name to check
        :return: True if builtin, False otherwise
        """
        root_module = module_name.split(".")[0]
        return root_module in self.BUILTIN_MODULES
    
    def resolve(self, module_name: str, from_script: str) -> Path | None:
        """
        Resolve a module name to an absolute file path.
        
        :param module_name: The module name (e.g., 'foo.bar' or './local')
        :param from_script: Path of the script requiring this module
        :return: Absolute path to the module file, or None if builtin
        :raises ModuleNotFoundError: If module cannot be found
        :raises CModuleNotSupportedError: If module is a C module
        """
        if self.is_builtin_module(module_name):
            return None
        
        from_script_path = Path(from_script).resolve()
        
        if module_name.startswith("./") or module_name.startswith("../"):
            return self._resolve_relative(module_name, from_script_path)
        
        module_path = module_name.replace(".", "/")
        
        for search_path in self.search_paths:
            lua_candidates = [
                search_path / f"{module_path}.lua",
                search_path / module_path / "init.lua",
            ]
            
            for candidate in lua_candidates:
                if candidate.exists():
                    return candidate.resolve()
            
            for ext in self.C_EXTENSIONS:
                c_candidate = search_path / f"{module_path}{ext}"
                if c_candidate.exists():
                    raise CModuleNotSupportedError(module_name, str(c_candidate))
        
        raise ModuleNotFoundError(
            module_name,
            from_script,
            [str(p) for p in self.search_paths]
        )
        
    def _resolve_relative(self, module_name: str, from_script_path: Path) -> Path:
        """
        Resolve a relative module path.
        
        :param module_name: Relative module name
        :param from_script_path: Absolute path of the requiring script
        :return: Absolute path to the module file
        :raises ModuleNotFoundError: If module cannot be found
        :raises CModuleNotSupportedError: If module is a C module
        """
        base_dir = from_script_path.parent
        target_path = (base_dir / module_name).resolve()
        
        candidates: list[Path] = []
        if target_path.suffix == ".lua":
            candidates.append(target_path)
        else:
            candidates.extend([
                Path(f"{target_path}.lua"),
                target_path / "init.lua",
            ])
        
        for candidate in candidates:
            if candidate.exists():
                return candidate.resolve()
        
        for ext in self.C_EXTENSIONS:
            c_candidate = Path(f"{target_path}{ext}")
            if c_candidate.exists():
                raise CModuleNotSupportedError(module_name, str(c_candidate))
        
        raise ModuleNotFoundError(
            module_name,
            str(from_script_path),
            [str(base_dir)]
        )


class DependencyAnalyzer:
    """
    Analyzes Lua script dependencies and builds dependency list.
    
    This analyzer performs recursive dependency extraction, circular
    dependency detection, dependency count limitation, and topological
    sorting of dependencies.
    """
    
    __slots__ = (
        "entry_script",
        "max_dependencies",
        "resolver",
        "visited",
        "stack",
        "dependency_graph",
        "dependency_count",
    )
    
    def __init__(self, entry_script: str, max_dependencies: int = 36) -> None:
        """
        Initialize the dependency analyzer.
        
        :param entry_script: Path to the entry Lua script
        :param max_dependencies: Maximum number of dependencies allowed
        """
        self.entry_script = Path(entry_script).resolve()
        self.max_dependencies = max_dependencies
        
        if not self.entry_script.exists():
            raise ScriptNotFoundError(str(entry_script))
        
        self.resolver = ModuleResolver(self.entry_script.parent)
        
        self.visited: set[Path] = set()
        self.stack: list[Path] = []
        self.dependency_graph: dict[Path, list[Path]] = {}
        self.dependency_count: int = 0
    
    def analyze(self) -> list[str]:
        """
        Perform complete dependency analysis.
        
        :return: List of dependency file paths (absolute, topologically sorted)
        """
        self._analyze_recursive(self.entry_script)
        
        total_count = len(self.visited) - 1
        if total_count > self.max_dependencies:
            raise DependencyLimitExceededError(total_count, self.max_dependencies)
        
        return self._generate_manifest()
    
    def _analyze_recursive(self, script_path: Path) -> None:
        """Recursively analyze a single script and its dependencies."""
        if script_path in self.stack:
            idx = self.stack.index(script_path)
            chain = [str(p) for p in self.stack[idx:]] + [str(script_path)]
            raise CircularDependencyError(chain)

        if script_path in self.visited:
            return

        if script_path != self.entry_script:
            prospective_total = self.dependency_count + 1
            if prospective_total > self.max_dependencies:
                raise DependencyLimitExceededError(prospective_total, self.max_dependencies)
            self.dependency_count = prospective_total

        if not script_path.exists():
            raise ScriptNotFoundError(str(script_path))

        try:
            source_code = script_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            try:
                source_code = script_path.read_text(encoding="gbk")
            except UnicodeDecodeError:
                source_code = script_path.read_text(encoding="latin-1")

        lexer = LuaLexer(source_code, str(script_path))
        requires = lexer.extract_requires()

        self.stack.append(script_path)

        dependencies: list[Path] = []
        seen: set[Path] = set()

        for module_name, line_num in requires:
            try:
                dep_path = self.resolver.resolve(module_name, str(script_path))
                if dep_path is None:
                    continue
                if dep_path not in seen:
                    seen.add(dep_path)
                    dependencies.append(dep_path)
                    self._analyze_recursive(dep_path)
            except (ModuleNotFoundError, CModuleNotSupportedError):
                raise

        self.dependency_graph[script_path] = dependencies

        self.stack.pop()
        self.visited.add(script_path)

    def _generate_manifest(self) -> list[str]:
        """
        Generate topologically sorted dependency manifest.
        
        Dependencies are ordered such that each module appears before
        any module that depends on it.
        
        :return: List of dependency file paths (excluding entry script)
        """
        sorted_deps: list[str] = []
        visited: set[Path] = set()
        
        def visit(node: Path) -> None:
            if node in visited:
                return
            visited.add(node)
            
            for dep in self.dependency_graph.get(node, []):
                visit(dep)
            
            sorted_deps.append(str(node))
        
        visit(self.entry_script)
        
        if str(self.entry_script) in sorted_deps:
            sorted_deps.remove(str(self.entry_script))
        
        return sorted_deps


def analyze_dependencies(
    entry_script: str,
    manual_mode: bool = False,
    max_dependencies: int = 36
) -> list[str]:
    """
    Analyze Lua script dependencies.
    
    This is the main entry point for dependency analysis.
    
    :param entry_script: Path to the entry Lua script
    :param manual_mode: If True, skip automatic analysis and return empty list
    :param max_dependencies: Maximum number of dependencies allowed
    :return: List of dependency file paths (absolute, topologically sorted)
    """
    if manual_mode:
        return []
    
    analyzer = DependencyAnalyzer(entry_script, max_dependencies)
    return analyzer.analyze()


def print_dependency_list(entry_script: str, max_dependencies: int = 36) -> None:
    """
    Print the dependency list for a Lua script.
    
    :param entry_script: Path to the entry Lua script
    :param max_dependencies: Maximum number of dependencies allowed
    """
    analyzer = DependencyAnalyzer(entry_script, max_dependencies)
    deps = analyzer.analyze()
    
    print(f"Dependencies for {Path(entry_script).name}:")
    
    if not deps:
        print("  (no dependencies)")
        return
    
    for i, dep_path in enumerate(deps, 1):
        print(f"  {i}. {Path(dep_path).name}")
```

`engine.py`:  

```python
"""
Compilation engine for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides the core compilation functionality using luastatic
to build standalone executables from Lua scripts.

:author: WaterRun
:file: engine.py
:date: 2025-12-05
"""

import os
import shutil
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from .exceptions import (
    CompilationFailedError,
    CompilerNotFoundError,
    LuastaticNotFoundError,
    OutputFileNotFoundError,
    ScriptNotFoundError,
)

if TYPE_CHECKING:
    from collections.abc import Sequence


def verify_environment() -> None:
    """
    Verify that required tools are available in PATH.
    
    :raises LuastaticNotFoundError: If luastatic is not installed
    :raises CompilerNotFoundError: If gcc is not available
    """
    if not shutil.which("luastatic"):
        raise LuastaticNotFoundError()
    
    if not shutil.which("gcc"):
        raise CompilerNotFoundError("gcc")


def _find_lua_library() -> str | None:
    """
    Find the Lua shared library path based on the Lua interpreter in PATH.
    
    :return: Path to Lua library, or None if not found
    """
    lua_executable = shutil.which("lua")
    if not lua_executable:
        return None
    
    lua_path = Path(lua_executable).resolve()
    
    try:
        result = subprocess.run(
            [str(lua_path), "-v"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False
        )
        version_output = result.stdout.strip() or result.stderr.strip()
    except (subprocess.TimeoutExpired, OSError):
        version_output = ""
    
    version_suffix = ""
    for ver in ("5.4", "5.3", "5.2", "5.1"):
        if f"Lua {ver}" in version_output:
            version_suffix = ver
            break
    
    bin_dir = lua_path.parent
    prefix_dir = bin_dir.parent
    
    candidate_dirs = [
        prefix_dir / "lib64",
        prefix_dir / "lib",
        prefix_dir / "lib" / "x86_64-linux-gnu",
        prefix_dir / "lib" / "aarch64-linux-gnu",
        prefix_dir / "lib" / "i386-linux-gnu",
        bin_dir,
        Path("/usr/lib64"),
        Path("/usr/lib"),
        Path("/usr/local/lib64"),
        Path("/usr/local/lib"),
        Path("/usr/lib/x86_64-linux-gnu"),
        Path("/usr/lib/aarch64-linux-gnu"),
    ]
    
    if os.name == "nt":
        candidate_dirs.extend([bin_dir, prefix_dir, prefix_dir / "bin"])
    
    lib_names: list[str] = []
    if version_suffix:
        if os.name == "nt":
            lib_names.extend([
                f'lua{version_suffix.replace(".", "")}.dll',
                f"lua{version_suffix}.dll",
                "lua.dll",
            ])
        else:
            lib_names.extend([
                f"liblua{version_suffix}.so",
                f"liblua-{version_suffix}.so",
                f"liblua{version_suffix}.a",
                "liblua.so",
                "liblua.a",
            ])
    else:
        if os.name == "nt":
            lib_names.extend(["lua54.dll", "lua53.dll", "lua52.dll", "lua51.dll", "lua.dll"])
        else:
            lib_names.extend([
                "liblua5.4.so", "liblua5.3.so", "liblua5.2.so", "liblua5.1.so",
                "liblua-5.4.so", "liblua-5.3.so", "liblua-5.2.so", "liblua-5.1.so",
                "liblua.so",
                "liblua5.4.a", "liblua5.3.a", "liblua5.2.a", "liblua5.1.a",
                "liblua.a",
            ])
    
    for candidate_dir in candidate_dirs:
        if not candidate_dir.exists():
            continue
        for lib_name in lib_names:
            lib_path = candidate_dir / lib_name
            if lib_path.exists():
                return str(lib_path.resolve())
    
    try:
        pkg_names = (
            [f"lua{version_suffix}", f"lua-{version_suffix}", "lua"]
            if version_suffix
            else ["lua5.4", "lua5.3", "lua"]
        )
        for pkg_name in pkg_names:
            result = subprocess.run(
                ["pkg-config", "--variable=libdir", pkg_name],
                capture_output=True,
                text=True,
                timeout=5,
                check=False
            )
            if result.returncode == 0 and result.stdout.strip():
                libdir = Path(result.stdout.strip())
                if libdir.exists():
                    for lib_name in lib_names:
                        lib_path = libdir / lib_name
                        if lib_path.exists():
                            return str(lib_path.resolve())
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        ...
    
    return None


def _cleanup_temp_files(entry_path: Path, output_dir: Path) -> list[str]:
    """
    Clean up temporary .c files generated by luastatic.
    
    :param entry_path: Path to the entry script
    :param output_dir: Directory where compilation was performed
    :return: List of deleted file paths
    """
    deleted: list[str] = []
    entry_name = entry_path.stem
    
    patterns = [
        f"{entry_name}.luastatic.c",
        f"{entry_name}.lua.c",
        f"{entry_name}.c",
    ]
    
    for pattern in patterns:
        temp_file = output_dir / pattern
        if temp_file.exists():
            try:
                temp_file.unlink()
                deleted.append(str(temp_file))
            except OSError:
                ...
    
    for c_file in output_dir.glob("*.luastatic.c"):
        if str(c_file) not in deleted:
            try:
                c_file.unlink()
                deleted.append(str(c_file))
            except OSError:
                ...
    
    return deleted


def compile_lua_script(
    entry_script: str,
    dependencies: Sequence[str],
    output: str | None = None,
    verbose: bool = False,
) -> str:
    """
    Compile Lua script with dependencies into standalone executable.
    
    :param entry_script: Path to entry Lua script
    :param dependencies: List of dependency file paths
    :param output: Output executable path (optional)
    :param verbose: Enable verbose output
    :return: Path to generated executable
    """
    verify_environment()
    
    entry_path = Path(entry_script).resolve()
    if not entry_path.exists():
        raise ScriptNotFoundError(str(entry_script))
    
    if output:
        output_path = Path(output).resolve()
        output_dir = output_path.parent
    else:
        output_dir = Path.cwd()
        output_name = entry_path.stem + (".exe" if os.name == "nt" else "")
        output_path = output_dir / output_name
    
    output_dir.mkdir(parents=True, exist_ok=True)
    
    command = ["luastatic", str(entry_path)]
    
    for dep in dependencies:
        dep_path = Path(dep).resolve()
        if not dep_path.exists():
            if verbose:
                print(f"Warning: Dependency not found: {dep}")
            continue
        command.append(str(dep_path))
    
    if lua_lib := _find_lua_library():
        command.append(lua_lib)
        if verbose:
            print(f"Using Lua library: {lua_lib}")
    else:
        if verbose:
            print("Warning: Lua library not found, luastatic may fail")
    
    command.extend(["-o", str(output_path)])
    
    if verbose:
        print(f"Executing: {' '.join(command)}")
        print(f"Working directory: {output_dir}")
    
    result = subprocess.run(
        command,
        cwd=str(output_dir),
        capture_output=True,
        text=True,
    )
    
    _cleanup_temp_files(entry_path, output_dir)
    
    if result.returncode != 0:
        raise CompilationFailedError(
            " ".join(command),
            result.returncode,
            result.stderr,
        )
    
    if verbose and result.stdout:
        print(result.stdout)
    
    if not output_path.exists():
        raise OutputFileNotFoundError(str(output_path))
    
    if verbose:
        print(f"Compilation successful: {output_path}")
    
    return str(output_path)


def get_environment_status() -> dict[str, bool]:
    """
    Get status of compilation environment.
    
    :return: Dictionary with tool availability status
    """
    return {
        "luastatic": bool(shutil.which("luastatic")),
        "gcc": bool(shutil.which("gcc")),
        "lua": bool(shutil.which("lua")),
        "lua_library": bool(_find_lua_library()),
    }


def print_environment_status() -> None:
    """Print compilation environment status."""
    status = get_environment_status()
    
    print("Compilation Environment Status:")
    print("=" * 50)
    
    for tool, available in status.items():
        symbol = "✓" if available else "✗"
        print(f"{symbol} {tool}")
    
    if lua_lib := _find_lua_library():
        print(f"  Path: {lua_lib}")
    
    print("=" * 50)
    
    if not status["luastatic"]:
        print("\nInstall luastatic:")
        print("  luarocks install luastatic")
    
    if not status["gcc"]:
        print("\nInstall gcc:")
        print("  Ubuntu/Debian: sudo apt install build-essential")
        print("  Fedora/RHEL:   sudo dnf install gcc")
        print("  Windows:       https://github.com/niXman/mingw-builds-binaries")
    
    if not status["lua"]:
        print("\nInstall Lua:")
        print("  Ubuntu/Debian: sudo apt install lua5.4")
        print("  Fedora/RHEL:   sudo dnf install lua")
        print("  Windows:       https://www.lua.org/download.html")
    
    if not status["lua_library"]:
        print("\nLua library not found. Install Lua development files:")
        print("  Ubuntu/Debian: sudo apt install liblua5.4-dev")
        print("  Fedora/RHEL:   sudo dnf install lua-devel")
```

`exceptions.py`:  

```python
"""
Custom exception classes for luainstaller.
https://github.com/Water-Run/luainstaller

:author: WaterRun
:file: exceptions.py
:date: 2025-12-05
"""

from abc import ABC


class LuaInstallerException(ABC, Exception):
    """
    Abstract base class for all luainstaller exceptions.
    
    All custom exceptions in luainstaller should inherit from this class
    to provide a unified exception hierarchy.
    """
    
    def __init__(self, message: str, details: str | None = None) -> None:
        """
        Initialize the exception.
        
        :param message: The main error message
        :param details: Additional details about the error
        """
        self.message = message
        self.details = details
        super().__init__(self._format_message())
    
    def _format_message(self) -> str:
        """Format the complete error message."""
        return f"{self.message}\nDetails: {self.details}" if self.details else self.message


class ScriptNotFoundError(LuaInstallerException):
    """
    Raised when a Lua script file cannot be found.
    
    This occurs when the entry script or a required dependency
    script does not exist at the specified path.
    """
    
    def __init__(self, script_path: str) -> None:
        """
        Initialize the ScriptNotFoundError.
        
        :param script_path: The path to the script that was not found
        """
        super().__init__(f"Lua script not found: {script_path}")
        self.script_path = script_path


class DependencyAnalysisError(LuaInstallerException):
    """
    Base class for dependency analysis related errors.
    
    This can occur due to circular dependencies, malformed require
    statements, or other issues during dependency tree construction.
    """
    
    def __init__(self, script_path: str, reason: str) -> None:
        """
        Initialize the DependencyAnalysisError.
        
        :param script_path: The script where analysis failed
        :param reason: Description of why analysis failed
        """
        super().__init__(
            f"Dependency analysis failed for '{script_path}'",
            reason
        )
        self.script_path = script_path
        self.reason = reason


class CircularDependencyError(DependencyAnalysisError):
    """
    Raised when a circular dependency is detected.
    
    This occurs when script A requires script B, which in turn
    requires script A (directly or indirectly).
    """
    
    def __init__(self, dependency_chain: list[str]) -> None:
        """
        Initialize the CircularDependencyError.
        
        :param dependency_chain: The chain of dependencies forming the cycle
        """
        chain_str = " -> ".join(dependency_chain)
        super().__init__(
            dependency_chain[0],
            f"Circular dependency detected: {chain_str}"
        )
        self.dependency_chain = dependency_chain


class DynamicRequireError(DependencyAnalysisError):
    """
    Raised when a dynamic require statement is detected.
    
    Dynamic requires cannot be statically analyzed and must be
    converted to static form or manually specified.
    """
    
    def __init__(self, script_path: str, line_number: int, statement: str) -> None:
        """
        Initialize the DynamicRequireError.
        
        :param script_path: The script containing the dynamic require
        :param line_number: Line number where the dynamic require was found
        :param statement: The actual require statement
        """
        super().__init__(
            script_path,
            f"Dynamic require detected at line {line_number}: {statement}\n"
            f"Only static require statements can be analyzed. "
            f"Use require('module_name') with a literal string."
        )
        self.line_number = line_number
        self.statement = statement


class DependencyLimitExceededError(DependencyAnalysisError):
    """
    Raised when the total number of dependencies exceeds the limit.
    
    To prevent infinite loops or excessive compilation times,
    there is a configurable limit on total dependencies.
    """
    
    def __init__(self, current_count: int, limit: int) -> None:
        """
        Initialize the DependencyLimitExceededError.
        
        :param current_count: The current dependency count
        :param limit: The maximum allowed dependencies
        """
        super().__init__(
            "<multiple>",
            f"Total dependency count ({current_count}) exceeds limit ({limit}). "
            f"This may indicate circular dependencies or an overly complex project."
        )
        self.current_count = current_count
        self.limit = limit


class ModuleNotFoundError(DependencyAnalysisError):
    """
    Raised when a required module cannot be resolved to a file path.
    
    This occurs when the module is not found in any search path.
    """
    
    def __init__(self, module_name: str, script_path: str, searched_paths: list[str]) -> None:
        """
        Initialize the ModuleNotFoundError.
        
        :param module_name: The module name that couldn't be found
        :param script_path: The script that requires this module
        :param searched_paths: List of paths where the module was searched
        """
        paths_str = "\n  - ".join(searched_paths)
        super().__init__(
            script_path,
            f"Cannot resolve module '{module_name}'.\n"
            f"Searched in:\n  - {paths_str}\n"
            f"Check if the module name is correct or if it needs to be installed via LuaRocks."
        )
        self.module_name = module_name
        self.searched_paths = searched_paths


class CModuleNotSupportedError(DependencyAnalysisError):
    """
    Raised when a C module (.so, .dll) is encountered.
    
    C modules require special compilation handling and are not
    currently supported by the automatic dependency analyzer.
    """
    
    def __init__(self, module_name: str, module_path: str) -> None:
        """
        Initialize the CModuleNotSupportedError.
        
        :param module_name: The name of the C module
        :param module_path: The path to the C module file
        """
        super().__init__(
            module_path,
            f"C module '{module_name}' detected at '{module_path}'.\n"
            f"C modules (.so, .dll, .dylib) are not supported by automatic dependency analysis.\n"
            f"You may need to compile them manually or use --manual mode."
        )
        self.module_name = module_name
        self.module_path = module_path


class CompilationError(LuaInstallerException):
    """
    Base class for compilation related errors.
    
    This occurs when the underlying compilation process fails.
    """
    ...


class LuastaticNotFoundError(CompilationError):
    """
    Raised when luastatic command is not found in the system.
    
    User needs to install luastatic via: luarocks install luastatic
    """
    
    def __init__(self) -> None:
        super().__init__(
            "luastatic not found in system",
            "Please install it via: luarocks install luastatic"
        )


class CompilerNotFoundError(CompilationError):
    """
    Raised when C compiler (gcc/clang) is not found in the system.
    
    User needs to install a C compiler to compile Lua scripts.
    """
    
    def __init__(self, compiler_name: str = "gcc") -> None:
        """
        Initialize the CompilerNotFoundError.
        
        :param compiler_name: Name of the compiler that was not found
        """
        super().__init__(
            f"C compiler '{compiler_name}' not found in system",
            "Please install a C compiler (gcc/clang/MinGW)"
        )
        self.compiler_name = compiler_name


class CompilationFailedError(CompilationError):
    """
    Raised when the compilation process fails.
    
    This occurs when luastatic returns a non-zero exit code.
    """
    
    def __init__(self, command: str, return_code: int, stderr: str | None = None) -> None:
        """
        Initialize the CompilationFailedError.
        
        :param command: The compilation command that failed
        :param return_code: The exit code from luastatic
        :param stderr: Standard error output from compilation
        """
        details = f"Command: {command}\nReturn code: {return_code}"
        if stderr:
            details += f"\nStderr: {stderr}"
        super().__init__("Compilation failed", details)
        self.command = command
        self.return_code = return_code
        self.stderr = stderr


class OutputFileNotFoundError(CompilationError):
    """
    Raised when the expected output file is not found after compilation.
    
    This can happen if luastatic succeeds but doesn't generate the
    expected executable file.
    """
    
    def __init__(self, expected_path: str) -> None:
        """
        Initialize the OutputFileNotFoundError.
        
        :param expected_path: The expected path of the output file
        """
        super().__init__(
            f"Output file not found: {expected_path}",
            "Compilation appeared to succeed but output file was not generated"
        )
        self.expected_path = expected_path
```

`gui.py`:  

```python
"""
Graphical user interface for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides a simple Tkinter-based GUI that wraps
the luainstaller CLI commands.

:author: WaterRun
:email: linzhangrun49@gmail.com
:file: gui.py
:date: 2025-12-05
"""

import os
import subprocess
import sys
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import NoReturn


VERSION = "1.0"
WINDOW_TITLE = "luainstaller-gui@waterrun"
WINDOW_WIDTH = 600
WINDOW_HEIGHT = 450
PROJECT_URL = "https://github.com/Water-Run/luainstallers/tree/main/luainstaller"


class LuaInstallerGUI:
    """
    GUI wrapper for luainstaller CLI.
    
    Provides a minimal interface for selecting entry Lua script
    and invoking the CLI build command.
    """

    def __init__(self, root: tk.Tk) -> None:
        """
        Initialize the GUI application.
        
        :param root: The Tkinter root window
        """
        self.root = root
        self.root.title(WINDOW_TITLE)
        self.root.resizable(False, False)

        self.entry_script_var = tk.StringVar()
        self.output_path_var = tk.StringVar()

        self._setup_styles()
        self._setup_ui()

        self.entry_script_var.trace_add("write", self._on_entry_changed)

    def _setup_styles(self) -> None:
        """Setup ttk styles for modern appearance."""
        style = ttk.Style()

        try:
            if os.name == "nt":
                style.theme_use("vista")
            else:
                available = style.theme_names()
                for theme in ("clam", "alt", "default"):
                    if theme in available:
                        style.theme_use(theme)
                        break
        except tk.TclError:
            ...

        if os.name == "nt":
            self._font_normal = ("Segoe UI", 9)
            self._font_bold = ("Segoe UI", 10, "bold")
            self._font_title = ("Segoe UI", 14, "bold")
            self._font_mono = ("Consolas", 9)
        else:
            self._font_normal = ("Sans", 9)
            self._font_bold = ("Sans", 10, "bold")
            self._font_title = ("Sans", 14, "bold")
            self._font_mono = ("Monospace", 9)

        style.configure("Title.TLabel", font=self._font_title)
        style.configure("Hint.TLabel", font=self._font_normal,
                        foreground="#666666")
        style.configure(
            "Link.TLabel",
            font=(self._font_normal[0], self._font_normal[1], "underline"),
            foreground="#0066cc",
        )
        style.configure("Build.TButton", font=self._font_bold,
                        padding=(20, 10))
        style.configure("TLabelframe.Label", font=self._font_normal)

    def _setup_ui(self) -> None:
        """Setup the user interface components."""
        main_frame = ttk.Frame(self.root, padding=20)
        main_frame.pack(fill=tk.BOTH, expand=True)

        self._create_header(main_frame)
        self._create_input_section(main_frame)
        self._create_output_section(main_frame)
        self._create_log_section(main_frame)
        self._create_build_section(main_frame)
        self._create_footer(main_frame)

    def _create_header(self, parent: ttk.Frame) -> None:
        """
        Create the header section.
        
        :param parent: Parent frame
        """
        header_frame = ttk.Frame(parent)
        header_frame.pack(fill=tk.X, pady=(0, 15))

        ttk.Label(header_frame, text="luainstaller", style="Title.TLabel").pack(
            anchor=tk.W
        )

        ttk.Label(
            header_frame,
            text="GUI provides basic build functionality only. "
            "For full features, use CLI or library.",
            style="Hint.TLabel",
            wraplength=560,
        ).pack(anchor=tk.W, pady=(5, 0))

    def _create_input_section(self, parent: ttk.Frame) -> None:
        """
        Create the entry script input section.
        
        :param parent: Parent frame
        """
        input_frame = ttk.LabelFrame(parent, text="Entry Script", padding=10)
        input_frame.pack(fill=tk.X, pady=(0, 10))

        entry_row = ttk.Frame(input_frame)
        entry_row.pack(fill=tk.X)

        self.entry_script_entry = ttk.Entry(
            entry_row, textvariable=self.entry_script_var
        )
        self.entry_script_entry.pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10)
        )

        ttk.Button(
            entry_row, text="Browse", command=self._browse_entry_script, width=10
        ).pack(side=tk.RIGHT)

    def _create_output_section(self, parent: ttk.Frame) -> None:
        """
        Create the output path display section.
        
        :param parent: Parent frame
        """
        output_frame = ttk.LabelFrame(
            parent, text="Output Path (auto-generated)", padding=10
        )
        output_frame.pack(fill=tk.X, pady=(0, 10))

        self.output_path_entry = ttk.Entry(
            output_frame, textvariable=self.output_path_var, state="readonly"
        )
        self.output_path_entry.pack(fill=tk.X)

    def _create_log_section(self, parent: ttk.Frame) -> None:
        """
        Create the CLI output section.
        
        :param parent: Parent frame
        """
        log_frame = ttk.LabelFrame(parent, text="CLI Output", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        text_frame = ttk.Frame(log_frame)
        text_frame.pack(fill=tk.BOTH, expand=True)

        scrollbar = ttk.Scrollbar(text_frame, orient=tk.VERTICAL)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.log_text = tk.Text(
            text_frame,
            height=8,
            state=tk.DISABLED,
            wrap=tk.WORD,
            font=self._font_mono,
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scrollbar.config(command=self.log_text.yview)
        self.log_text.config(yscrollcommand=scrollbar.set)

    def _create_build_section(self, parent: ttk.Frame) -> None:
        """
        Create the build button section.
        
        :param parent: Parent frame
        """
        build_frame = ttk.Frame(parent)
        build_frame.pack(fill=tk.X, pady=(0, 10))

        self.build_button = ttk.Button(
            build_frame,
            text="Build Executable",
            command=self._run_build,
            style="Build.TButton",
        )
        self.build_button.pack(expand=True)

    def _create_footer(self, parent: ttk.Frame) -> None:
        """
        Create the footer with link.
        
        :param parent: Parent frame
        """
        footer_frame = ttk.Frame(parent)
        footer_frame.pack(fill=tk.X, side=tk.BOTTOM)

        ttk.Separator(footer_frame, orient=tk.HORIZONTAL).pack(
            fill=tk.X, pady=(0, 8))

        link_label = ttk.Label(
            footer_frame, text="GitHub", style="Link.TLabel", cursor="hand2"
        )
        link_label.pack(side=tk.RIGHT)
        link_label.bind("<Button-1>", lambda _: webbrowser.open(PROJECT_URL))

    def _log(self, message: str) -> None:
        """
        Append message to the log text widget.
        
        :param message: Message to append
        """
        self.log_text.config(state=tk.NORMAL)
        self.log_text.insert(tk.END, message)
        self.log_text.see(tk.END)
        self.log_text.config(state=tk.DISABLED)

    def _log_clear(self) -> None:
        """Clear the log text widget."""
        self.log_text.config(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.config(state=tk.DISABLED)

    def _browse_entry_script(self) -> None:
        """Open file dialog to select entry script."""
        filepath = filedialog.askopenfilename(
            title="Select Entry Lua Script",
            filetypes=[("Lua Scripts", "*.lua"), ("All Files", "*.*")],
        )
        if filepath:
            self.entry_script_var.set(filepath)

    def _on_entry_changed(self, *_: object) -> None:
        """Handle entry script path change to auto-generate output path."""
        entry_script = self.entry_script_var.get().strip()

        if not entry_script:
            self.output_path_var.set("")
            return

        entry_path = Path(entry_script)

        if entry_path.suffix == ".lua":
            output_name = entry_path.stem + (".exe" if os.name == "nt" else "")
            output_path = Path.cwd() / output_name
            self.output_path_var.set(str(output_path))
        else:
            self.output_path_var.set("")

    def _validate_inputs(self) -> bool:
        """
        Validate user inputs.
        
        :return: True if valid, False otherwise
        """
        entry_script = self.entry_script_var.get().strip()

        if not entry_script:
            messagebox.showerror("Error", "Please select an entry script.")
            return False

        entry_path = Path(entry_script)

        if not entry_path.exists():
            messagebox.showerror("Error", f"Script not found:\n{entry_script}")
            return False

        if entry_path.suffix != ".lua":
            messagebox.showerror("Error", "Entry script must be a .lua file.")
            return False

        if not self.output_path_var.get().strip():
            messagebox.showerror("Error", "Output path not generated.")
            return False

        return True

    def _run_build(self) -> None:
        """Run the CLI build command."""
        if not self._validate_inputs():
            return

        entry_script = self.entry_script_var.get().strip()
        output_path = self.output_path_var.get().strip()

        cmd = [
            sys.executable,
            "-m",
            "luainstaller",
            "build",
            entry_script,
            "-output",
            output_path,
            "--detail",
        ]

        self._log_clear()
        self._log(f"$ {' '.join(cmd)}\n\n")

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=str(Path(entry_script).parent),
            )

            if result.stdout:
                self._log(result.stdout)
            if result.stderr:
                self._log(result.stderr)

            if result.returncode == 0:
                self._log("\n[Build completed successfully]")
            else:
                self._log(
                    f"\n[Build failed with exit code {result.returncode}]")

        except FileNotFoundError:
            self._log("[Error: Python interpreter not found]")
        except Exception as e:
            self._log(f"[Error: {e}]")


def run_gui() -> None:
    """Run the luainstaller GUI application."""
    root = tk.Tk()

    try:
        if os.name == "nt":
            root.iconbitmap(default="")
    except tk.TclError:
        ...

    _ = LuaInstallerGUI(root)

    root.update_idletasks()
    x = (root.winfo_screenwidth() // 2) - (WINDOW_WIDTH // 2)
    y = (root.winfo_screenheight() // 2) - (WINDOW_HEIGHT // 2)
    root.geometry(f"{WINDOW_WIDTH}x{WINDOW_HEIGHT}+{x}+{y}")

    root.mainloop()


def gui_main() -> NoReturn:
    """GUI entry point that runs the application."""
    run_gui()
    sys.exit(0)


if __name__ == "__main__":
    gui_main()
```

`logger.py`:  

```python
"""
Logging system for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides a centralized logging system that persists logs
to disk using simpsave and provides query functionality.

:author: WaterRun
:file: logger.py
:date: 2025-12-05
"""

from datetime import datetime
from enum import StrEnum
from typing import Any, TypedDict

import simpsave as ss


class LogLevel(StrEnum):
    """Log level enumeration."""
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    SUCCESS = "success"


class LogEntry(TypedDict):
    """Type definition for a log entry."""
    timestamp: str
    level: str
    source: str
    action: str
    message: str
    details: dict[str, Any]


_LOG_KEY = "luainstaller_logs"
_LOG_FILE = ":ss:luainstaller_logs.json"
_MAX_LOGS = 1000


def log(
    log_level: LogLevel | str,
    source: str,
    action: str,
    message: str,
    **details: Any
) -> None:
    """
    Log an event to the persistent log store.
    
    :param log_level: Log level (debug, info, warning, error, success)
    :param source: Source of the log (e.g., 'cli', 'gui', 'api')
    :param action: Action being performed (e.g., 'build', 'analyze')
    :param message: Human-readable message
    :param details: Additional key-value details to store
    """
    
    entry: LogEntry = {
        "timestamp": datetime.now().isoformat(),
        "level": str(log_level),
        "source": source,
        "action": action,
        "message": message,
        "details": details,
    }
    
    try:
        existing: list[LogEntry] = []
        
        try:
            if ss.has(_LOG_KEY, file=_LOG_FILE):
                loaded = ss.read(_LOG_KEY, file=_LOG_FILE)
                if isinstance(loaded, list):
                    existing = loaded
        except FileNotFoundError:
            existing = []
        
        existing.append(entry)
        
        if len(existing) > _MAX_LOGS:
            existing = existing[-_MAX_LOGS:]
        
        ss.write(_LOG_KEY, existing, file=_LOG_FILE)
    except Exception:
        ...


def get_logs(
    limit: int | None = None,
    level: LogLevel | str | None = None,
    source: str | None = None,
    action: str | None = None,
    descending: bool = True,
) -> list[LogEntry]:
    """
    Retrieve logs from persistent storage with optional filtering.
    
    :param limit: Maximum number of logs to return
    :param level: Filter by log level
    :param source: Filter by source
    :param action: Filter by action
    :param descending: Sort by timestamp descending (newest first)
    :return: List of log entries
    """
    
    try:
        try:
            if not ss.has(_LOG_KEY, file=_LOG_FILE):
                return []
        except FileNotFoundError:
            return []
        
        logs: list[LogEntry] = ss.read(_LOG_KEY, file=_LOG_FILE)
        
        if not isinstance(logs, list):
            return []
        
        if level is not None:
            level_str = str(level)
            logs = [e for e in logs if e.get("level") == level_str]
        
        if source is not None:
            logs = [e for e in logs if e.get("source") == source]
        
        if action is not None:
            logs = [e for e in logs if e.get("action") == action]
        
        logs.sort(key=lambda x: x.get("timestamp", ""), reverse=descending)
        
        if limit is not None and limit > 0:
            logs = logs[:limit]
        
        return logs
    
    except Exception:
        return []


def clear_logs() -> bool:
    """
    Clear all stored logs.
    
    :return: True if successful, False otherwise
    """
    
    try:
        ss.write(_LOG_KEY, [], file=_LOG_FILE)
        return True
    except Exception:
        return False


def log_error(source: str, action: str, message: str, **details: Any) -> None:
    """Log an error message."""
    log(LogLevel.ERROR, source, action, message, **details)


def log_success(source: str, action: str, message: str, **details: Any) -> None:
    """Log a success message."""
    log(LogLevel.SUCCESS, source, action, message, **details)
```

我现在需要编写lua程序, 以进行测试功能. 确保符合luainstaller的能力范围.  
