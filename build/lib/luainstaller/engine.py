"""
Compilation engine for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides the core compilation functionality using multiple engines:
- luastatic: Compile to true native binary (Linux only)
- srlua: Bundle using precompiled srlua binaries (Windows/Linux)

:author: WaterRun
:file: engine.py
:date: 2025-12-15
"""

import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING

from .exceptions import (
    CompilationFailedError,
    CompilerNotFoundError,
    EngineNotFoundError,
    LuastaticNotFoundError,
    OutputFileNotFoundError,
    ScriptNotFoundError,
    SrluaNotFoundError,
)
from .source_bundler import SourceBundler

if TYPE_CHECKING:
    from collections.abc import Sequence


ENGINES: dict[str, dict[str, str]] = {
    "luastatic": {
        "type": "luastatic",
        "platform": "linux",
        "description": "Compile to true native binary (Linux only)",
    },
    "srlua": {
        "type": "srlua",
        "platform": "auto",
        "description": "Default srlua for current platform",
    },
    "winsrlua515": {
        "type": "srlua",
        "platform": "windows",
        "lua_version": "5.1.5",
        "arch": "64",
        "binary": "srlua515.exe",
        "glue": "glue515.exe",
    },
    "winsrlua515-32": {
        "type": "srlua",
        "platform": "windows",
        "lua_version": "5.1.5",
        "arch": "32",
        "binary": "srlua515-32.exe",
        "glue": "glue515-32.exe",
    },
    "winsrlua548": {
        "type": "srlua",
        "platform": "windows",
        "lua_version": "5.4.8",
        "arch": "64",
        "binary": "srlua548.exe",
        "glue": "glue548.exe",
    },
    "linsrlua515": {
        "type": "srlua",
        "platform": "linux",
        "lua_version": "5.1.5",
        "arch": "64",
        "binary": "srlua515",
        "glue": "glue515",
    },
    "linsrlua515-32": {
        "type": "srlua",
        "platform": "linux",
        "lua_version": "5.1.5",
        "arch": "32",
        "binary": "srlua515-32",
        "glue": "glue515-32",
    },
    "linsrlua548": {
        "type": "srlua",
        "platform": "linux",
        "lua_version": "5.4.8",
        "arch": "64",
        "binary": "srlua548",
        "glue": "glue548",
    },
}


def get_supported_engines() -> list[str]:
    """
    Get list of all supported engine names.
    
    :return: List of engine names
    """
    return list(ENGINES.keys())


def get_default_engine() -> str:
    """
    Get the default engine for the current platform.
    
    :return: Default engine name
    """
    return "srlua" if os.name == "nt" else "luastatic"


def get_platform_srlua_engine() -> str:
    """
    Get the appropriate srlua engine for the current platform.
    
    :return: srlua engine name
    """
    if os.name == "nt":
        return "winsrlua548"
    return "linsrlua548"


def _get_srlua_binary_path(engine_name: str) -> tuple[Path, Path]:
    """
    Get the paths to srlua and glue binaries for the specified engine.
    
    :param engine_name: Name of the srlua engine
    :return: Tuple of (srlua_path, glue_path)
    :raises SrluaNotFoundError: If binaries are not found
    """
    engine_config = ENGINES.get(engine_name)
    if not engine_config or engine_config["type"] != "srlua":
        raise EngineNotFoundError(engine_name, get_supported_engines())

    if engine_name == "srlua":
        engine_name = get_platform_srlua_engine()
        engine_config = ENGINES[engine_name]

    package_dir = Path(__file__).parent

    if os.name == "nt":
        srlua_dir = package_dir / "srlua" / "windows"
    else:
        srlua_dir = package_dir / "srlua" / "linux"

    srlua_binary = srlua_dir / engine_config["binary"]
    glue_binary = srlua_dir / engine_config["glue"]

    if not srlua_binary.exists():
        raise SrluaNotFoundError(engine_name)
    if not glue_binary.exists():
        raise SrluaNotFoundError(engine_name)

    if os.name != "nt":
        for binary in (srlua_binary, glue_binary):
            current_mode = binary.stat().st_mode
            if not (current_mode & stat.S_IXUSR):
                binary.chmod(current_mode | stat.S_IXUSR |
                             stat.S_IXGRP | stat.S_IXOTH)

    return srlua_binary, glue_binary


def verify_luastatic_environment() -> None:
    """
    Verify that required tools for luastatic are available in PATH.
    
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
            check=False,
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
            lib_names.extend([
                "lua54.dll", "lua53.dll", "lua52.dll", "lua51.dll", "lua.dll"
            ])
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
                check=False,
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


def _compile_with_luastatic(
    entry_script: str,
    dependencies: "Sequence[str]",
    output: str | None = None,
    verbose: bool = False,
) -> str:
    """
    Compile Lua script with dependencies into standalone executable using luastatic.
    
    :param entry_script: Path to entry Lua script
    :param dependencies: List of dependency file paths
    :param output: Output executable path (optional)
    :param verbose: Enable verbose output
    :return: Path to generated executable
    """
    verify_luastatic_environment()

    entry_path = Path(entry_script).resolve()
    if not entry_path.exists():
        raise ScriptNotFoundError(str(entry_script))

    if output:
        output_path = Path(output).resolve()
        output_dir = output_path.parent
    else:
        output_dir = Path.cwd()
        output_name = entry_path.stem
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
    elif verbose:
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


def _compile_with_srlua(
    entry_script: str,
    dependencies: "Sequence[str]",
    engine: str,
    output: str | None = None,
    verbose: bool = False,
) -> str:
    """
    Compile Lua script with dependencies into executable using srlua.
    
    :param entry_script: Path to entry Lua script
    :param dependencies: List of dependency file paths
    :param engine: srlua engine name
    :param output: Output executable path (optional)
    :param verbose: Enable verbose output
    :return: Path to generated executable
    """
    entry_path = Path(entry_script).resolve()
    if not entry_path.exists():
        raise ScriptNotFoundError(str(entry_script))

    srlua_binary, glue_binary = _get_srlua_binary_path(engine)

    if output:
        output_path = Path(output).resolve()
        if os.name == "nt" and not output_path.suffix:
            output_path = output_path.with_suffix(".exe")
    else:
        output_name = entry_path.stem + (".exe" if os.name == "nt" else "")
        output_path = Path.cwd() / output_name

    output_path.parent.mkdir(parents=True, exist_ok=True)

    if verbose:
        print(f"Using srlua engine: {engine}")
        print(f"srlua binary: {srlua_binary}")
        print(f"glue binary: {glue_binary}")

    bundler = SourceBundler(str(entry_path), list(dependencies))

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".lua",
        delete=False,
        encoding="utf-8",
    ) as temp_file:
        bundled_script = temp_file.name

    try:
        bundler.bundle(bundled_script)

        if verbose:
            print(f"Bundled script: {bundled_script}")

        command = [
            str(glue_binary),
            str(srlua_binary),
            bundled_script,
            str(output_path),
        ]

        if verbose:
            print(f"Executing: {' '.join(command)}")

        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
        )

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

        if os.name != "nt":
            current_mode = output_path.stat().st_mode
            output_path.chmod(
                current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            )

        if verbose:
            print(f"Compilation successful: {output_path}")

        return str(output_path)

    finally:
        try:
            Path(bundled_script).unlink()
        except OSError:
            ...


def compile_lua_script(
    entry_script: str,
    dependencies: "Sequence[str]",
    engine: str | None = None,
    output: str | None = None,
    verbose: bool = False,
) -> str:
    """
    Compile Lua script with dependencies into standalone executable.
    
    :param entry_script: Path to entry Lua script
    :param dependencies: List of dependency file paths
    :param engine: Engine name (defaults to platform default)
    :param output: Output executable path (optional)
    :param verbose: Enable verbose output
    :return: Path to generated executable
    :raises EngineNotFoundError: If specified engine is not available
    """
    if engine is None:
        engine = get_default_engine()

    if engine not in ENGINES:
        raise EngineNotFoundError(engine, get_supported_engines())

    engine_config = ENGINES[engine]

    if engine_config["type"] == "luastatic":
        return _compile_with_luastatic(
            entry_script,
            dependencies,
            output=output,
            verbose=verbose,
        )

    return _compile_with_srlua(
        entry_script,
        dependencies,
        engine=engine,
        output=output,
        verbose=verbose,
    )


def get_environment_status() -> dict[str, bool | str]:
    """
    Get status of compilation environment.
    
    :return: Dictionary with tool availability status
    """
    status: dict[str, bool | str] = {
        "luastatic": bool(shutil.which("luastatic")),
        "gcc": bool(shutil.which("gcc")),
        "lua": bool(shutil.which("lua")),
        "lua_library": bool(_find_lua_library()),
        "default_engine": get_default_engine(),
        "platform": "windows" if os.name == "nt" else "linux",
    }

    for engine_name, config in ENGINES.items():
        if config["type"] == "srlua" and engine_name != "srlua":
            try:
                _get_srlua_binary_path(engine_name)
                status[f"srlua_{engine_name}"] = True
            except (SrluaNotFoundError, EngineNotFoundError):
                status[f"srlua_{engine_name}"] = False

    return status


def print_environment_status() -> None:
    """Print compilation environment status."""
    status = get_environment_status()

    print("Compilation Environment Status:")
    print("=" * 60)

    print(f"\nPlatform: {status['platform']}")
    print(f"Default engine: {status['default_engine']}")

    print("\nluastatic engine requirements:")
    for tool in ("luastatic", "gcc", "lua", "lua_library"):
        symbol = "✓" if status[tool] else "✗"
        print(f"  {symbol} {tool}")

    if lua_lib := _find_lua_library():
        print(f"    Path: {lua_lib}")

    print("\nsrlua engines:")
    for engine_name in ENGINES:
        if engine_name in ("luastatic", "srlua"):
            continue
        key = f"srlua_{engine_name}"
        if key in status:
            symbol = "✓" if status[key] else "✗"
            print(f"  {symbol} {engine_name}")

    print("=" * 60)

    if not status["luastatic"]:
        print("\nTo use luastatic engine, install luastatic:")
        print("  luarocks install luastatic")

    if not status["gcc"]:
        print("\nTo use luastatic engine, install gcc:")
        print("  Ubuntu/Debian: sudo apt install build-essential")
        print("  Fedora/RHEL:   sudo dnf install gcc")

    if not status["lua"]:
        print("\nTo use luastatic engine, install Lua:")
        print("  Ubuntu/Debian: sudo apt install lua5.4")
        print("  Fedora/RHEL:   sudo dnf install lua")
