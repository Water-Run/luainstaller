"""
Command-line interface for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides the CLI functionality for luainstaller,
including commands for dependency analysis, compilation, and log viewing.

:author: WaterRun
:file: cli.py
:date: 2025-12-15
"""

import sys
from pathlib import Path
from typing import NoReturn

from .dependency_analyzer import analyze_dependencies
from .engine import (
    compile_lua_script,
    get_default_engine,
    get_supported_engines,
    print_environment_status,
)
from .exceptions import LuaInstallerException
from .logger import LogLevel, get_logs, log_error, log_success
from .source_bundler import bundle_sources


VERSION = "2.0"
PROJECT_URL = "https://github.com/Water-Run/luainstaller"


HELP_MESSAGE = f"""\
luainstaller - Package Lua scripts into standalone executables

Usage:
    luainstaller                              Show version info
    luainstaller help                         Show this help message
    luainstaller engines                      List supported engines
    luainstaller logs [options]               View operation logs
    luainstaller analyze <script> [options]   Analyze dependencies
    luainstaller build <script> [options]     Build executable

Commands:

  help
      Display this help message.

  engines
      List all supported packaging engines.

  logs [-limit <n>] [--asc] [-level <level>]
      Display stored operation logs.
      
      Options:
          -limit <n>      Limit the number of logs to display
          --asc           Display in ascending order (default: descending)
          -level <level>  Filter by level (debug, info, warning, error, success)

  analyze <entry_script> [-max <n>] [--detail] [-bundle <output>]
      Perform dependency analysis on the entry script.
      
      Options:
          -max <n>        Maximum dependency count (default: 36)
          --detail        Show detailed analysis output
          -bundle <path>  Bundle to single .lua script file

  build <entry_script> [options]
      Compile Lua script into standalone executable.
      
      Options:
          -engine <name>       Packaging engine (default: platform-specific)
          -require <scripts>   Additional dependency scripts (comma-separated)
          -max <n>             Maximum dependency count (default: 36)
          -output <path>       Output executable path
          --manual             Disable automatic dependency analysis
          --detail             Show detailed compilation output

Engines:
    luastatic    - Compile to true native binary (Linux only)
    srlua        - Default srlua for current platform
    winsrlua515  - Windows Lua 5.1.5 (64-bit)
    winsrlua515-32 - Windows Lua 5.1.5 (32-bit)
    winsrlua548  - Windows Lua 5.4.8
    linsrlua515  - Linux Lua 5.1.5 (64-bit)
    linsrlua515-32 - Linux Lua 5.1.5 (32-bit)
    linsrlua548  - Linux Lua 5.4.8

Examples:
    luainstaller build hello.lua
    luainstaller build main.lua -engine srlua -output ./bin/myapp
    luainstaller build app.lua -require utils.lua,config.lua --manual
    luainstaller analyze main.lua -max 100 --detail
    luainstaller analyze main.lua -bundle bundled.lua
    luainstaller logs -limit 20 --asc

Visit: {PROJECT_URL}
"""


# ASCII-compatible symbols for cross-platform compatibility
SYMBOL_SUCCESS = "[OK]"
SYMBOL_ERROR = "[FAIL]"
SYMBOL_WARNING = "[WARN]"
SYMBOL_DEBUG = "[DEBUG]"
SYMBOL_INFO = "[INFO]"


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
    print(f"{SYMBOL_SUCCESS} {message}")


def print_info(message: str) -> None:
    """Print an informational message."""
    print(f"  {message}")


def cmd_engines() -> int:
    """Handle the 'engines' command."""
    engines = get_supported_engines()
    default = get_default_engine()

    print("Supported engines:")
    print("=" * 50)

    for engine in engines:
        marker = " (default)" if engine == default else ""
        print(f"  {engine}{marker}")

    print("=" * 50)
    print(f"\nDefault engine for this platform: {default}")

    return 0


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

        symbol = {
            "success": SYMBOL_SUCCESS,
            "error": SYMBOL_ERROR,
            "warning": SYMBOL_WARNING,
            "debug": SYMBOL_DEBUG,
        }.get(log_level, SYMBOL_INFO)

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
        print_info(
            "Usage: luainstaller analyze <script> [-max <n>] [--detail] [-bundle <path>]")
        return 1

    max_deps = 36
    detail = False
    bundle_output: str | None = None

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

            case "-bundle":
                bundle_output = parser.consume_value("-bundle")

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

        dependencies = analyze_dependencies(
            str(entry_path), max_dependencies=max_deps)

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

        if bundle_output:
            all_scripts = dependencies + [str(entry_path.resolve())]
            bundle_sources(str(entry_path.resolve()),
                           dependencies, bundle_output)
            print(f"\nBundled to: {bundle_output}")

        log_success("cli", "analyze",
                    f"Analyzed {entry_path.name}: {len(dependencies)} deps")
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
    engine: str | None = None
    manual = False
    detail = False

    while parser.has_next():
        match parser.consume():
            case "-engine":
                engine = parser.consume_value("-engine")
                if engine not in get_supported_engines():
                    print_error(f"Unknown engine: {engine}")
                    print_info(
                        f"Available engines: {', '.join(get_supported_engines())}")
                    return 1

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

    selected_engine = engine if engine else get_default_engine()

    try:
        if detail:
            print(f"Building: {entry_path.resolve()}")
            print(f"Engine: {selected_engine}")
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
            dependencies = analyze_dependencies(
                str(entry_path), max_dependencies=max_deps
            )
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
            engine=selected_engine,
            output=output,
            verbose=detail,
        )

        print_success(f"Build successful: {output_path}")

        log_success(
            "cli",
            "build",
            f"Built {entry_path.name} -> {Path(output_path).name}",
            engine=selected_engine,
        )

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

        case "engines":
            return cmd_engines()

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
    