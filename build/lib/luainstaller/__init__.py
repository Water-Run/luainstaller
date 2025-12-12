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
