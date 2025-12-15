"""
luainstaller - Python library for packaging Lua scripts into standalone executables.
https://github.com/Water-Run/luainstaller

This package provides tools for:
- Dependency analysis of Lua scripts
- Compilation to standalone executables using luastatic or srlua
- Command-line and graphical interfaces
- Multi-engine support for Windows and Linux platforms

:author: WaterRun
:file: __init__.py
:date: 2025-12-15
"""

from pathlib import Path
from typing import Any

from .dependency_analyzer import analyze_dependencies
from .engine import (
    compile_lua_script,
    get_default_engine,
    get_environment_status,
    get_supported_engines,
)
from .exceptions import (
    CModuleNotSupportedError,
    CircularDependencyError,
    CompilationError,
    CompilationFailedError,
    CompilerNotFoundError,
    DependencyAnalysisError,
    DependencyLimitExceededError,
    DynamicRequireError,
    EngineNotFoundError,
    LuaInstallerException,
    LuastaticNotFoundError,
    ModuleNotFoundError,
    OutputFileNotFoundError,
    ScriptNotFoundError,
    SrluaNotFoundError,
)
from .logger import LogEntry, LogLevel, clear_logs
from .logger import get_logs as _get_logs
from .logger import log_error, log_success
from .source_bundler import SourceBundler, bundle_sources


__version__ = "2.0.0"
__author__ = "WaterRun"
__email__ = "linzhangrun49@gmail.com"
__url__ = "https://github.com/Water-Run/luainstaller"


__all__ = [
    # Version info
    "__version__",
    "__author__",
    "__email__",
    "__url__",
    # Public API
    "get_logs",
    "clear_logs",
    "get_engines",
    "analyze",
    "bundle_to_singlefile",
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
    "SrluaNotFoundError",
    "EngineNotFoundError",
    "CompilerNotFoundError",
    "CompilationFailedError",
    "OutputFileNotFoundError",
    # Logger types
    "LogLevel",
    "LogEntry",
    # Source bundler
    "SourceBundler",
    "bundle_sources",
]


def get_logs(
    limit: int | None = None,
    _range: range | None = None,
    desc: bool = True,
) -> list[dict[str, Any]]:
    r"""
    返回luainstaller日志.
    
    :param limit: 返回数限制, None表示不限制
    :param _range: 返回范围限制, None表示不限制
    :param desc: 是否倒序返回
    :return list[dict[str, Any]]: 日志字典组成的列表
    
    Example::
    
        >>> import luainstaller
        >>> log_1 = luainstaller.get_logs()  # 以倒序获取全部日志
        >>> log_2 = luainstaller.get_logs(limit=100, _range=range(128, 256), desc=False)
    """
    logs = _get_logs(limit=None, descending=desc)

    if _range is not None:
        logs = [log for i, log in enumerate(logs) if i in _range]

    if limit is not None and limit > 0:
        logs = logs[:limit]

    return logs


def get_engines() -> list[str]:
    r"""
    返回luainstaller支持的全部引擎名称.
    
    :return list[str]: 引擎名称列表
    
    Example::
    
        >>> import luainstaller
        >>> engines = luainstaller.get_engines()
    """
    return get_supported_engines()


def analyze(entry: str, max_deps: int = 36) -> list[str]:
    """
    对入口脚本执行依赖分析.
    
    Recursively scans the entry script for require statements and resolves
    all dependencies. Supports standard require patterns including:
    
    - require 'module'
    - require "module"
    - require('module')
    - require("module")
    - require([[module]])
    
    Dynamic require statements (e.g., require(variable)) are not supported
    and will raise DynamicRequireError.
    
    :param entry: 入口脚本路径
    :param max_deps: 最大递归依赖数, 默认36
    :return list[str]: 分析得到的依赖脚本路径列表
    :raises ScriptNotFoundError: If the entry script does not exist.
    :raises CircularDependencyError: If circular dependencies are detected.
    :raises DynamicRequireError: If a dynamic require statement is found.
    :raises DependencyLimitExceededError: If dependency count exceeds max_deps.
    :raises ModuleNotFoundError: If a required module cannot be resolved.
    
    Example::
    
        >>> import luainstaller
        >>> deps_1 = luainstaller.analyze("main.lua")
        >>> deps_2 = luainstaller.analyze("main.lua", max_deps=112)
    """
    return analyze_dependencies(entry, max_dependencies=max_deps)


def bundle_to_singlefile(scripts: list[str], output: str) -> None:
    r"""
    打包输出至单文件.
    
    :param scripts: 需要打包的脚本列表
    :param output: 输出路径
    
    Example::
    
        >>> import luainstaller
        >>> luainstaller.bundle_to_singlefile(["a.lua", "b.lua"], "c.lua")
        >>> luainstaller.bundle_to_singlefile(
        ...     luainstaller.analyze("main.lua"), "bundled.lua"
        ... )
    """
    if not scripts:
        raise ValueError("scripts list cannot be empty")

    entry_script = scripts[-1] if len(scripts) > 0 else scripts[0]
    dependencies = scripts[:-1] if len(scripts) > 1 else []

    bundler = SourceBundler(entry_script, dependencies)
    bundler.bundle(output)


def build(
    entry: str,
    engine: str | None = None,
    requires: list[str] | None = None,
    max_deps: int = 36,
    output: str | None = None,
    manual: bool = False,
) -> str:
    r"""
    执行脚本编译.
    
    This function performs the following steps:
    
    1. Analyzes dependencies automatically (unless manual mode is enabled)
    2. Merges manually specified dependencies with analyzed ones
    3. Selects the appropriate engine based on platform or user specification
    4. Invokes the engine to compile the executable
    
    :param entry: 入口脚本
    :param engine: 引擎名称, None使用平台默认引擎(Windows: srlua, Linux: luastatic)
    :param requires: 手动指定依赖列表; 若为空则仅依赖自动分析
    :param max_deps: 最大依赖树分析数
    :param output: 输出二进制路径, None使用默认规则
    :param manual: 禁用自动依赖分析
    :return str: 生成的可执行文件路径
    :raises ScriptNotFoundError: If the entry script or a required script does not exist.
    :raises EngineNotFoundError: If the specified engine is not available.
    :raises CompilationFailedError: If compilation returns a non-zero exit code.
    :raises OutputFileNotFoundError: If the output file was not created.
    
    Example::
    
        >>> import luainstaller
        >>> luainstaller.build("hello.lua")
        >>> luainstaller.build("app.lua", engine="winsrlua515")
        >>> luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)
        >>> luainstaller.build("test.lua", engine="linsrlua548", max_deps=100,
        ...                    output="../myProgram")
    """
    dependencies = [] if manual else analyze_dependencies(
        entry, max_dependencies=max_deps
    )

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

    selected_engine = engine if engine else get_default_engine()

    result = compile_lua_script(
        entry,
        dependencies,
        engine=selected_engine,
        output=output,
        verbose=False,
    )

    log_success(
        "api",
        "build",
        f"Built {Path(entry).name} -> {Path(result).name}",
        engine=selected_engine,
    )
    return result
