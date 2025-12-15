"""
Test script for luainstaller package.
https://github.com/Water-Run/luainstaller

This script tests all luainstaller functionality including:
- Library API (analyze, build, bundle_to_singlefile, get_engines, get_logs)
- CLI commands (help, engines, analyze, build)
- GUI launch

Usage:
    python test_luainstaller.py at_win    # Test on Windows
    python test_luainstaller.py at_lin    # Test on Linux

:author: WaterRun
:file: test_luainstaller.py
:date: 2025-12-15
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


DIVIDER = "=" * 70
SECTION_DIVIDER = "-" * 50


class TestResult:
    """Track test results."""

    __slots__ = ("passed", "failed", "skipped", "details")

    def __init__(self) -> None:
        self.passed: int = 0
        self.failed: int = 0
        self.skipped: int = 0
        self.details: list[tuple[str, str, str]] = []

    def add_pass(self, name: str, message: str = "") -> None:
        self.passed += 1
        self.details.append((name, "PASS", message))
        print(f"  ✓ {name}")
        if message:
            print(f"    {message}")

    def add_fail(self, name: str, message: str) -> None:
        self.failed += 1
        self.details.append((name, "FAIL", message))
        print(f"  ✗ {name}")
        print(f"    Error: {message}")

    def add_skip(self, name: str, reason: str) -> None:
        self.skipped += 1
        self.details.append((name, "SKIP", reason))
        print(f"  ○ {name} (skipped: {reason})")

    def summary(self) -> None:
        print(f"\n{DIVIDER}")
        print("TEST SUMMARY")
        print(DIVIDER)
        total = self.passed + self.failed + self.skipped
        print(f"Total:   {total}")
        print(f"Passed:  {self.passed}")
        print(f"Failed:  {self.failed}")
        print(f"Skipped: {self.skipped}")

        if self.failed > 0:
            print(f"\n{SECTION_DIVIDER}")
            print("FAILED TESTS:")
            for name, status, message in self.details:
                if status == "FAIL":
                    print(f"  ✗ {name}: {message}")

        print(DIVIDER)


def print_header(title: str) -> None:
    """Print a section header."""
    print(f"\n{DIVIDER}")
    print(f" {title}")
    print(DIVIDER)


def print_subheader(title: str) -> None:
    """Print a subsection header."""
    print(f"\n{SECTION_DIVIDER}")
    print(f" {title}")
    print(SECTION_DIVIDER)


def cleanup_file(path: Path) -> None:
    """Safely remove a file if it exists."""
    try:
        if path.exists():
            path.unlink()
    except OSError:
        ...


def cleanup_files(paths: list[Path]) -> None:
    """Safely remove multiple files."""
    for path in paths:
        cleanup_file(path)


class LuaInstallerTester:
    """Test runner for luainstaller."""

    __slots__ = ("platform", "results", "test_dir",
                 "is_windows", "cleanup_list")

    def __init__(self, platform: str) -> None:
        """
        Initialize the tester.
        
        :param platform: 'at_win' for Windows, 'at_lin' for Linux
        """
        self.platform = platform
        self.is_windows = platform == "at_win"
        self.results = TestResult()
        self.test_dir = Path(__file__).parent.resolve()
        self.cleanup_list: list[Path] = []

    def run_all_tests(self) -> int:
        """
        Run all tests.
        
        :return: Exit code (0 for success, 1 for failures)
        """
        print(DIVIDER)
        print(" LUAINSTALLER TEST SUITE")
        print(f" Platform: {'Windows' if self.is_windows else 'Linux'}")
        print(f" Test directory: {self.test_dir}")
        print(DIVIDER)

        try:
            self._test_import()
            self._test_library_api()
            self._test_cli()
            self._test_gui_launch()
        finally:
            self._cleanup()

        self.results.summary()

        return 0 if self.results.failed == 0 else 1

    def _cleanup(self) -> None:
        """Clean up generated files."""
        print_subheader("Cleanup")
        cleanup_files(self.cleanup_list)
        print("  Cleaned up generated files")

    def _test_import(self) -> None:
        """Test that luainstaller can be imported."""
        print_header("IMPORT TESTS")

        try:
            import luainstaller
            self.results.add_pass(
                "Import luainstaller",
                f"Version: {luainstaller.__version__}"
            )
        except ImportError as e:
            self.results.add_fail("Import luainstaller", str(e))
            return

        required_attrs = [
            "__version__",
            "get_logs",
            "get_engines",
            "analyze",
            "bundle_to_singlefile",
            "build",
        ]

        for attr in required_attrs:
            if hasattr(luainstaller, attr):
                self.results.add_pass(f"Has attribute: {attr}")
            else:
                self.results.add_fail(
                    f"Has attribute: {attr}", "Attribute not found")

    def _test_library_api(self) -> None:
        """Test the library API."""
        print_header("LIBRARY API TESTS")

        import luainstaller

        self._test_get_engines(luainstaller)
        self._test_get_logs(luainstaller)
        self._test_analyze(luainstaller)
        self._test_bundle_to_singlefile(luainstaller)
        self._test_build(luainstaller)

    def _test_get_engines(self, luainstaller) -> None:
        """Test get_engines() function."""
        print_subheader("get_engines()")

        try:
            engines = luainstaller.get_engines()

            if isinstance(engines, list) and len(engines) > 0:
                self.results.add_pass(
                    "get_engines() returns list",
                    f"Engines: {', '.join(engines)}"
                )
            else:
                self.results.add_fail(
                    "get_engines() returns list",
                    f"Got: {type(engines).__name__}, length: {len(engines) if isinstance(engines, list) else 'N/A'}"
                )

            expected_engines = ["luastatic", "srlua"]
            for engine in expected_engines:
                if engine in engines:
                    self.results.add_pass(f"Engine '{engine}' available")
                else:
                    self.results.add_fail(
                        f"Engine '{engine}' available", "Not found in list")

            if self.is_windows:
                win_engines = ["winsrlua515", "winsrlua548"]
                for engine in win_engines:
                    if engine in engines:
                        self.results.add_pass(
                            f"Windows engine '{engine}' available")
            else:
                lin_engines = ["linsrlua515", "linsrlua548"]
                for engine in lin_engines:
                    if engine in engines:
                        self.results.add_pass(
                            f"Linux engine '{engine}' available")

        except Exception as e:
            self.results.add_fail("get_engines()", str(e))

    def _test_get_logs(self, luainstaller) -> None:
        """Test get_logs() function."""
        print_subheader("get_logs()")

        try:
            logs = luainstaller.get_logs()

            if isinstance(logs, list):
                self.results.add_pass(
                    "get_logs() returns list",
                    f"Log count: {len(logs)}"
                )
            else:
                self.results.add_fail(
                    "get_logs() returns list",
                    f"Got: {type(logs).__name__}"
                )

            logs_limited = luainstaller.get_logs(limit=5)
            if isinstance(logs_limited, list) and len(logs_limited) <= 5:
                self.results.add_pass("get_logs(limit=5) respects limit")
            else:
                self.results.add_fail(
                    "get_logs(limit=5) respects limit",
                    f"Got {len(logs_limited)} logs"
                )

            logs_asc = luainstaller.get_logs(desc=False)
            if isinstance(logs_asc, list):
                self.results.add_pass("get_logs(desc=False) works")
            else:
                self.results.add_fail("get_logs(desc=False) works", "Failed")

        except Exception as e:
            self.results.add_fail("get_logs()", str(e))

    def _test_analyze(self, luainstaller) -> None:
        """Test analyze() function."""
        print_subheader("analyze()")

        hello_world = self.test_dir / "hello_world" / "hello_world.lua"
        if hello_world.exists():
            try:
                deps = luainstaller.analyze(str(hello_world))

                if isinstance(deps, list):
                    self.results.add_pass(
                        "analyze() hello_world.lua",
                        f"Dependencies: {len(deps)}"
                    )
                else:
                    self.results.add_fail(
                        "analyze() hello_world.lua",
                        f"Got: {type(deps).__name__}"
                    )
            except Exception as e:
                self.results.add_fail("analyze() hello_world.lua", str(e))
        else:
            self.results.add_skip(
                "analyze() hello_world.lua", "File not found")

        snake_main = self.test_dir / "snake_game" / "main.lua"
        if snake_main.exists():
            try:
                deps = luainstaller.analyze(str(snake_main))

                if isinstance(deps, list) and len(deps) > 0:
                    self.results.add_pass(
                        "analyze() snake_game/main.lua",
                        f"Found {len(deps)} dependencies"
                    )

                    for dep in deps[:3]:
                        print(f"      - {Path(dep).name}")
                    if len(deps) > 3:
                        print(f"      ... and {len(deps) - 3} more")
                else:
                    self.results.add_fail(
                        "analyze() snake_game/main.lua",
                        "Expected dependencies but found none"
                    )
            except Exception as e:
                self.results.add_fail("analyze() snake_game/main.lua", str(e))
        else:
            self.results.add_skip(
                "analyze() snake_game/main.lua", "File not found")

        student_main = self.test_dir / "student_management_system" / "main.lua"
        if student_main.exists():
            try:
                deps = luainstaller.analyze(str(student_main), max_deps=100)
                self.results.add_pass(
                    "analyze() with max_deps=100",
                    f"Found {len(deps)} dependencies"
                )
            except Exception as e:
                self.results.add_fail("analyze() with max_deps=100", str(e))
        else:
            self.results.add_skip(
                "analyze() with max_deps=100", "File not found")

    def _test_bundle_to_singlefile(self, luainstaller) -> None:
        """Test bundle_to_singlefile() function."""
        print_subheader("bundle_to_singlefile()")

        snake_main = self.test_dir / "snake_game" / "main.lua"
        bundle_output = self.test_dir / "test_bundle_output.lua"
        self.cleanup_list.append(bundle_output)

        if snake_main.exists():
            try:
                deps = luainstaller.analyze(str(snake_main))
                all_scripts = deps + [str(snake_main)]

                luainstaller.bundle_to_singlefile(
                    all_scripts, str(bundle_output))

                if bundle_output.exists():
                    content = bundle_output.read_text(encoding="utf-8")
                    size_kb = len(content) / 1024

                    if "_MODULES" in content and "_require" in content:
                        self.results.add_pass(
                            "bundle_to_singlefile() snake_game",
                            f"Output size: {size_kb:.2f} KB"
                        )
                    else:
                        self.results.add_fail(
                            "bundle_to_singlefile() snake_game",
                            "Bundle doesn't contain expected runtime code"
                        )
                else:
                    self.results.add_fail(
                        "bundle_to_singlefile() snake_game",
                        "Output file not created"
                    )
            except Exception as e:
                self.results.add_fail(
                    "bundle_to_singlefile() snake_game", str(e))
        else:
            self.results.add_skip(
                "bundle_to_singlefile() snake_game", "File not found")

    def _test_build(self, luainstaller) -> None:
        """Test build() function."""
        print_subheader("build()")

        hello_world = self.test_dir / "hello_world" / "hello_world.lua"
        exe_suffix = ".exe" if self.is_windows else ""

        if self.is_windows:
            test_engines = ["srlua", "winsrlua548", "winsrlua515"]
        else:
            test_engines = ["linsrlua548", "linsrlua515"]
            if shutil.which("luastatic"):
                test_engines.insert(0, "luastatic")

        if hello_world.exists():
            for engine in test_engines:
                output_name = f"test_hello_{engine}{exe_suffix}"
                output_path = self.test_dir / output_name
                self.cleanup_list.append(output_path)

                try:
                    result = luainstaller.build(
                        str(hello_world),
                        engine=engine,
                        output=str(output_path),
                    )

                    if Path(result).exists():
                        size_kb = Path(result).stat().st_size / 1024
                        self.results.add_pass(
                            f"build() with engine={engine}",
                            f"Output: {output_name} ({size_kb:.2f} KB)"
                        )

                        try:
                            run_result = subprocess.run(
                                [str(result)],
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            if run_result.returncode == 0:
                                output_preview = run_result.stdout.strip()[:50]
                                self.results.add_pass(
                                    f"Execute {output_name}",
                                    f"Output: {output_preview}"
                                )
                            else:
                                self.results.add_fail(
                                    f"Execute {output_name}",
                                    f"Exit code: {run_result.returncode}"
                                )
                        except subprocess.TimeoutExpired:
                            self.results.add_fail(
                                f"Execute {output_name}", "Timeout")
                        except Exception as e:
                            self.results.add_fail(
                                f"Execute {output_name}", str(e))
                    else:
                        self.results.add_fail(
                            f"build() with engine={engine}",
                            "Output file not created"
                        )
                except Exception as e:
                    self.results.add_fail(
                        f"build() with engine={engine}", str(e))
        else:
            self.results.add_skip("build() tests", "hello_world.lua not found")

        snake_main = self.test_dir / "snake_game" / "main.lua"
        if snake_main.exists():
            default_engine = "srlua" if self.is_windows else "linsrlua548"
            output_name = f"test_snake{exe_suffix}"
            output_path = self.test_dir / output_name
            self.cleanup_list.append(output_path)

            try:
                result = luainstaller.build(
                    str(snake_main),
                    engine=default_engine,
                    output=str(output_path),
                )

                if Path(result).exists():
                    size_kb = Path(result).stat().st_size / 1024
                    self.results.add_pass(
                        "build() snake_game with dependencies",
                        f"Output: {output_name} ({size_kb:.2f} KB)"
                    )
                else:
                    self.results.add_fail(
                        "build() snake_game with dependencies",
                        "Output file not created"
                    )
            except Exception as e:
                self.results.add_fail(
                    "build() snake_game with dependencies", str(e))
        else:
            self.results.add_skip("build() snake_game", "File not found")

        student_main = self.test_dir / "student_management_system" / "main.lua"
        if student_main.exists():
            default_engine = "srlua" if self.is_windows else "linsrlua548"
            output_name = f"test_student_manual{exe_suffix}"
            output_path = self.test_dir / output_name
            self.cleanup_list.append(output_path)

            requires = [
                str(self.test_dir / "student_management_system" / "utils.lua"),
                str(self.test_dir / "student_management_system" / "student.lua"),
                str(self.test_dir / "student_management_system" / "storage.lua"),
            ]

            try:
                result = luainstaller.build(
                    str(student_main),
                    engine=default_engine,
                    requires=requires,
                    output=str(output_path),
                    manual=True,
                )

                if Path(result).exists():
                    self.results.add_pass(
                        "build() with manual=True and requires")
                else:
                    self.results.add_fail(
                        "build() with manual=True and requires",
                        "Output file not created"
                    )
            except Exception as e:
                self.results.add_fail(
                    "build() with manual=True and requires", str(e))
        else:
            self.results.add_skip("build() manual mode", "File not found")

    def _test_cli(self) -> None:
        """Test CLI commands."""
        print_header("CLI TESTS")

        cli_cmd = "luainstaller"

        self._test_cli_version(cli_cmd)
        self._test_cli_help(cli_cmd)
        self._test_cli_engines(cli_cmd)
        self._test_cli_analyze(cli_cmd)
        self._test_cli_build(cli_cmd)

    def _run_cli(
        self,
        args: list[str],
        timeout: int = 30,
        cwd: str | Path | None = None,
    ) -> subprocess.CompletedProcess:
        """
        Run a CLI command.
        
        :param args: Command arguments
        :param timeout: Timeout in seconds
        :param cwd: Working directory (defaults to test_dir)
        :return: Completed process
        """
        if cwd is None:
            cwd = self.test_dir

        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(cwd),
        )

    def _test_cli_version(self, cli_cmd: str) -> None:
        """Test CLI version command."""
        print_subheader("CLI: version")

        try:
            result = self._run_cli([cli_cmd])

            if result.returncode == 0 and "luainstaller" in result.stdout.lower():
                version_line = result.stdout.strip().split("\n")[0]
                self.results.add_pass("luainstaller (no args)", version_line)
            else:
                self.results.add_fail(
                    "luainstaller (no args)",
                    f"Exit code: {result.returncode}"
                )

            result = self._run_cli([cli_cmd, "--version"])
            if result.returncode == 0:
                self.results.add_pass("luainstaller --version")
            else:
                self.results.add_fail(
                    "luainstaller --version",
                    f"Exit code: {result.returncode}"
                )

        except Exception as e:
            self.results.add_fail("CLI version commands", str(e))

    def _test_cli_help(self, cli_cmd: str) -> None:
        """Test CLI help command."""
        print_subheader("CLI: help")

        try:
            result = self._run_cli([cli_cmd, "help"])

            if result.returncode == 0:
                help_text = result.stdout

                required_sections = ["Usage", "Commands", "Examples"]
                missing = [s for s in required_sections if s.lower()
                           not in help_text.lower()]

                if not missing:
                    self.results.add_pass(
                        "luainstaller help", "All sections present")
                else:
                    self.results.add_fail(
                        "luainstaller help",
                        f"Missing sections: {', '.join(missing)}"
                    )
            else:
                self.results.add_fail(
                    "luainstaller help",
                    f"Exit code: {result.returncode}"
                )

        except Exception as e:
            self.results.add_fail("CLI help command", str(e))

    def _test_cli_engines(self, cli_cmd: str) -> None:
        """Test CLI engines command."""
        print_subheader("CLI: engines")

        try:
            result = self._run_cli([cli_cmd, "engines"])

            if result.returncode == 0:
                output = result.stdout

                if "luastatic" in output and "srlua" in output:
                    self.results.add_pass(
                        "luainstaller engines", "Lists available engines")
                else:
                    self.results.add_fail(
                        "luainstaller engines",
                        "Expected engines not found in output"
                    )
            else:
                self.results.add_fail(
                    "luainstaller engines",
                    f"Exit code: {result.returncode}"
                )

        except Exception as e:
            self.results.add_fail("CLI engines command", str(e))

    def _test_cli_analyze(self, cli_cmd: str) -> None:
        """Test CLI analyze command."""
        print_subheader("CLI: analyze")

        snake_main = self.test_dir / "snake_game" / "main.lua"
        bundle_output = self.test_dir / "cli_bundle_output.lua"
        self.cleanup_list.append(bundle_output)

        if snake_main.exists():
            try:
                result = self._run_cli([
                    cli_cmd, "analyze",
                    str(snake_main),
                ])

                if result.returncode == 0 and "Dependencies" in result.stdout:
                    self.results.add_pass(
                        "luainstaller analyze snake_game/main.lua")
                else:
                    self.results.add_fail(
                        "luainstaller analyze snake_game/main.lua",
                        f"Exit code: {result.returncode}, stdout: {result.stdout[:100]}"
                    )

                result = self._run_cli([
                    cli_cmd, "analyze",
                    str(snake_main),
                    "--detail",
                ])

                if result.returncode == 0:
                    self.results.add_pass("luainstaller analyze --detail")
                else:
                    self.results.add_fail(
                        "luainstaller analyze --detail",
                        f"Exit code: {result.returncode}"
                    )

                result = self._run_cli([
                    cli_cmd, "analyze",
                    str(snake_main),
                    "-bundle", str(bundle_output),
                ])

                if result.returncode == 0 and bundle_output.exists():
                    self.results.add_pass("luainstaller analyze -bundle")
                else:
                    self.results.add_fail(
                        "luainstaller analyze -bundle",
                        f"Exit code: {result.returncode}, file exists: {bundle_output.exists()}"
                    )

            except Exception as e:
                self.results.add_fail("CLI analyze commands", str(e))
        else:
            self.results.add_skip("CLI analyze commands",
                                  "snake_game/main.lua not found")

    def _test_cli_build(self, cli_cmd: str) -> None:
        """Test CLI build command."""
        print_subheader("CLI: build")

        hello_world = self.test_dir / "hello_world" / "hello_world.lua"
        exe_suffix = ".exe" if self.is_windows else ""

        if hello_world.exists():
            output_path = self.test_dir / f"cli_test_hello{exe_suffix}"
            self.cleanup_list.append(output_path)

            engine = "srlua" if self.is_windows else "linsrlua548"

            try:
                result = self._run_cli([
                    cli_cmd, "build",
                    str(hello_world),
                    "-engine", engine,
                    "-output", str(output_path),
                ])

                if result.returncode == 0 and output_path.exists():
                    self.results.add_pass(
                        f"luainstaller build -engine {engine}",
                        f"Output: {output_path.name}"
                    )
                else:
                    self.results.add_fail(
                        f"luainstaller build -engine {engine}",
                        f"Exit code: {result.returncode}, stderr: {result.stderr[:200]}"
                    )

                output_path2 = self.test_dir / \
                    f"cli_test_hello_detail{exe_suffix}"
                self.cleanup_list.append(output_path2)

                result = self._run_cli([
                    cli_cmd, "build",
                    str(hello_world),
                    "-engine", engine,
                    "-output", str(output_path2),
                    "--detail",
                ])

                if result.returncode == 0:
                    self.results.add_pass("luainstaller build --detail")
                else:
                    self.results.add_fail(
                        "luainstaller build --detail",
                        f"Exit code: {result.returncode}"
                    )

            except Exception as e:
                self.results.add_fail("CLI build commands", str(e))
        else:
            self.results.add_skip("CLI build commands",
                                  "hello_world.lua not found")

        student_dir = self.test_dir / "student_management_system"
        student_main = student_dir / "main.lua"
        if student_main.exists():
            output_path = self.test_dir / \
                f"cli_test_student_manual{exe_suffix}"
            self.cleanup_list.append(output_path)

            engine = "srlua" if self.is_windows else "linsrlua548"

            requires_files = [
                str(student_dir / "utils.lua"),
                str(student_dir / "student.lua"),
                str(student_dir / "storage.lua"),
            ]
            requires_str = ",".join(requires_files)

            try:
                result = self._run_cli(
                    [
                        cli_cmd, "build",
                        str(student_main),
                        "-engine", engine,
                        "-output", str(output_path),
                        "-require", requires_str,
                        "--manual",
                    ],
                    timeout=60,
                )

                if result.returncode == 0 and output_path.exists():
                    self.results.add_pass(
                        "luainstaller build --manual -require")
                else:
                    error_info = result.stderr[:300] if result.stderr else result.stdout[:300]
                    self.results.add_fail(
                        "luainstaller build --manual -require",
                        f"Exit code: {result.returncode}, output: {error_info}"
                    )

            except Exception as e:
                self.results.add_fail("CLI build --manual", str(e))
        else:
            self.results.add_skip(
                "CLI build --manual", "student_management_system/main.lua not found")

    def _test_gui_launch(self) -> None:
        """Test GUI launch."""
        print_header("GUI TEST")

        print("\n  The GUI will be launched for manual testing.")
        print("  Please verify:")
        print("    1. Window opens correctly")
        print("    2. Engine information is displayed")
        print("    3. Browse button works")
        print("    4. Build button is functional")
        print("  Close the GUI window to continue.\n")

        try:
            input("  Press Enter to launch GUI...")
        except EOFError:
            self.results.add_skip("GUI launch", "Non-interactive mode")
            return

        try:
            result = subprocess.run(
                ["luainstaller-gui"],
                timeout=300,
            )

            if result.returncode == 0:
                self.results.add_pass("GUI launched and closed normally")
            else:
                self.results.add_fail(
                    "GUI launch",
                    f"Exit code: {result.returncode}"
                )

        except subprocess.TimeoutExpired:
            self.results.add_fail("GUI launch", "Timeout (5 minutes)")
        except FileNotFoundError:
            self.results.add_fail(
                "GUI launch", "luainstaller-gui not found in PATH")
        except Exception as e:
            self.results.add_fail("GUI launch", str(e))


def print_usage() -> None:
    """Print usage information."""
    print("Usage: python test_luainstaller.py <platform>")
    print()
    print("Platforms:")
    print("  at_win    Test on Windows (skips luastatic)")
    print("  at_lin    Test on Linux (includes luastatic if available)")
    print()
    print("Examples:")
    print("  python test_luainstaller.py at_win")
    print("  python test_luainstaller.py at_lin")


def main() -> NoReturn:
    """Main entry point."""
    if len(sys.argv) != 2:
        print_usage()
        sys.exit(1)

    platform = sys.argv[1].lower()

    if platform not in ("at_win", "at_lin"):
        print(f"Error: Unknown platform '{platform}'")
        print()
        print_usage()
        sys.exit(1)

    actual_platform = "at_win" if os.name == "nt" else "at_lin"
    if platform != actual_platform:
        print(
            f"Warning: Specified platform '{platform}' differs from actual platform '{actual_platform}'")
        print("Some tests may not work correctly.")
        print()

    tester = LuaInstallerTester(platform)
    exit_code = tester.run_all_tests()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
