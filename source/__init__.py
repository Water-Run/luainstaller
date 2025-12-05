"""
luainstaller - Python library for packaging Lua scripts into standalone executables.
https://github.com/Water-Run/luainstallers/tree/main/luainstaller

This package provides tools for:
- Dependency analysis of Lua scripts
- Compilation to standalone executables using luastatic
- Command-line and graphical interfaces

:author: WaterRun
:email: linzhangrun49@gmail.com
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
    返回luainstaller日志.
    
    :param limit: 返回数限制, None表示不限制
    :param level: 按日志级别过滤
    :param source: 按来源过滤 (如 'cli', 'gui', 'api')
    :param action: 按操作过滤 (如 'build', 'analyze')
    :param descending: 是否按时间倒序返回
    :return: 日志条目列表
    
    Example:
        >>> import luainstaller
        >>> logs = luainstaller.get_logs()
        >>> logs = luainstaller.get_logs(limit=100, level="error")
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
    对入口脚本执行依赖分析.
    
    :param entry: 入口脚本路径
    :param max_deps: 最大递归依赖数, 默认36
    :return: 分析得到的依赖脚本路径列表
    
    Example:
        >>> import luainstaller
        >>> deps = luainstaller.analyze("main.lua")
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
    执行脚本编译.
    
    :param entry: 入口脚本
    :param requires: 手动指定依赖列表; 若为空则仅依赖自动分析
    :param max_deps: 最大依赖树分析数
    :param output: 输出二进制路径, None 使用默认规则
    :param manual: 禁用自动依赖分析
    :return: 生成的可执行文件路径
    
    Example:
        >>> import luainstaller
        >>> luainstaller.build("hello.lua")
        >>> luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)
    """
    dependencies = [] if manual else analyze_dependencies(entry, max_dependencies=max_deps)
    
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
    
    log_success("api", "build", f"Built {Path(entry).name} -> {Path(result).name}")
    return result