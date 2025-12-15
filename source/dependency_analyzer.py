"""
Dependency analysis engine for Lua scripts.
https://github.com/Water-Run/luainstaller

This module provides comprehensive dependency analysis for Lua scripts,
including static require extraction, module path resolution, and dependency
list construction with cycle detection.

:author: WaterRun
:file: dependency_analyzer.py
:date: 2025-12-15
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

    __slots__ = ("source", "file_path", "pos", "line",
                 "state", "long_bracket_level")

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
        """
        Extract all static require statements from the source code.
        
        Scans through the Lua source code and identifies all require statements,
        including both direct require calls and pcall-wrapped requires. Returns
        a list of tuples containing the module name and line number.
        
        :return: List of (module_name, line_number) tuples
        """
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
                module_name = self._extract_long_string_literal(
                    level, start_line)
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
                module_name = self._extract_long_string_literal(
                    level, start_line)
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
            "Unterminated string in require statement",
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
            "Unterminated long string in require statement",
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

        if self.source[self.pos: self.pos + 2] == "..":
            raise DynamicRequireError(
                self.file_path,
                start_line,
                f"require('{module_name}' .. ...) - String concatenation not supported",
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
                check=False,
            )

            if result.returncode == 0 and result.stdout.strip():
                raw = result.stdout.strip()

                if "=" in raw and os.linesep in raw:
                    raw = raw.split(
                        os.linesep)[-1].strip().strip("'").strip('"')

                sep = ";" if os.name == "nt" else ":"
                lua_paths = raw.split(sep)

                for lua_path in lua_paths:
                    lua_path = lua_path.strip().strip("'").strip('"')

                    if lua_path.endswith("?.lua"):
                        lua_path = lua_path[: -len("?.lua")]
                    elif lua_path.endswith("?/init.lua"):
                        lua_path = lua_path[: -len("?/init.lua")]

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
                        chunk = chunk[: -len("?.lua")]
                    elif chunk.endswith("?/init.lua"):
                        chunk = chunk[: -len("?/init.lua")]
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
                    raise CModuleNotSupportedError(
                        module_name, str(c_candidate))

        raise ModuleNotFoundError(
            module_name,
            from_script,
            [str(p) for p in self.search_paths],
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
            [str(base_dir)],
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
            raise DependencyLimitExceededError(
                total_count, self.max_dependencies)

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
                raise DependencyLimitExceededError(
                    prospective_total, self.max_dependencies
                )
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
    max_dependencies: int = 36,
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
