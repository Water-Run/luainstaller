"""
Source bundler for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides functionality to merge multiple Lua scripts into a single
standalone script file with proper module isolation and require replacement.

:author: WaterRun
:file: source_bundler.py
:date: 2025-12-15
"""

import re
import tempfile
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Sequence


RUNTIME_TEMPLATE = """\
-- luainstaller bundled script
-- Generated: {timestamp}
-- Entry: {entry_name}

local _MODULES = {{}}
local _CACHE = {{}}

local _original_require = require
package.loaded = setmetatable(_CACHE, {{
    __index = function(t, k)
        local v = rawget(t, k)
        if v ~= nil then return v end
        return nil
    end
}})

local function _require(name)
    if _CACHE[name] ~= nil then
        return _CACHE[name]
    end
    
    local loader = _MODULES[name]
    if loader == nil then
        local ok, result = pcall(_original_require, name)
        if ok then
            _CACHE[name] = result
            return result
        end
        error("module '" .. name .. "' not found", 2)
    end
    
    local result = loader()
    if result == nil then
        result = true
    end
    _CACHE[name] = result
    return result
end

"""


MODULE_TEMPLATE = """\
_MODULES["{module_name}"] = function()
    local _ENV = setmetatable({{}}, {{__index = _G}})
    if setfenv then setfenv(1, _ENV) end
    
{module_code}
end

"""


ENTRY_TEMPLATE = """\
do
    local _ENV = setmetatable({{}}, {{__index = _G}})
    if setfenv then setfenv(1, _ENV) end
    
{entry_code}
end
"""


class SourceBundler:
    """
    Bundles multiple Lua scripts into a single standalone script.
    
    This bundler merges an entry script with all its dependencies into one file,
    with proper module isolation using Lua's _ENV mechanism. Each module runs in
    its own environment, preventing global variable pollution.
    """

    __slots__ = ("entry_script", "dependencies", "project_root")

    def __init__(self, entry_script: str, dependencies: "Sequence[str]") -> None:
        """
        Initialize the source bundler.
        
        :param entry_script: Absolute path to the entry Lua script
        :param dependencies: List of absolute paths to dependency files (excluding entry)
        """
        self.entry_script = Path(entry_script).resolve()
        self.dependencies = [Path(dep).resolve() for dep in dependencies]
        self.project_root = self._find_project_root()

    def bundle(self, output_path: str | None = None) -> str:
        """
        Bundle all scripts into a single Lua file.
        
        :param output_path: Output file path, or None to create a temp file
        :return: Absolute path to the generated script
        """
        bundled_content = self._generate_bundled_script()

        if output_path is not None:
            out_path = Path(output_path).resolve()
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(bundled_content, encoding="utf-8")
            return str(out_path)

        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".lua",
            delete=False,
            encoding="utf-8",
        ) as temp_file:
            temp_file.write(bundled_content)
            return temp_file.name

    def _find_project_root(self) -> Path:
        """
        Find the project root directory.
        
        Uses the entry script's parent directory as the project root,
        which ensures module names are relative to where the entry script lives.
        
        :return: Project root directory path
        """
        return self.entry_script.parent

    def _path_to_module_name(self, file_path: Path) -> str:
        """
        Convert an absolute file path to a module name.
        
        :param file_path: Absolute path to the Lua file
        :return: Standardized module name using forward slashes
        """
        try:
            relative = file_path.relative_to(self.project_root)
        except ValueError:
            relative = Path(file_path.name)

        module_name = str(relative)

        if module_name.endswith(".lua"):
            module_name = module_name[:-4]

        module_name = module_name.replace("\\", "/")

        return module_name

    def _read_file_content(self, file_path: Path) -> str:
        """
        Read file content with encoding fallback.
        
        Tries UTF-8, then GBK, then Latin-1.
        
        :param file_path: Path to the file
        :return: File content as string
        :raises FileNotFoundError: If file doesn't exist
        """
        if not file_path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        for encoding in ("utf-8", "gbk", "latin-1"):
            try:
                return file_path.read_text(encoding=encoding)
            except UnicodeDecodeError:
                continue

        return file_path.read_text(encoding="latin-1", errors="replace")

    def _rewrite_requires(self, source_code: str) -> str:
        """
        Rewrite require statements to use _require with normalized module names.
        
        Handles:
        - require('module')
        - require("module")
        - require 'module'
        - require "module"
        - require([[module]])
        - pcall(require, 'module')
        
        :param source_code: Original Lua source code
        :return: Source code with require replaced by _require
        """
        result = source_code

        patterns = [
            (
                r'\bpcall\s*\(\s*require\s*,\s*(["\'])([^"\']+)\1\s*\)',
                lambda m: f'pcall(_require, "{self._normalize_module_name(m.group(2))}")',
            ),
            (
                r'\bpcall\s*\(\s*require\s*,\s*\[\[([^\]]+)\]\]\s*\)',
                lambda m: f'pcall(_require, "{self._normalize_module_name(m.group(1))}")',
            ),
            (
                r'\brequire\s*\(\s*(["\'])([^"\']+)\1\s*\)',
                lambda m: f'_require("{self._normalize_module_name(m.group(2))}")',
            ),
            (
                r'\brequire\s*\(\s*\[\[([^\]]+)\]\]\s*\)',
                lambda m: f'_require("{self._normalize_module_name(m.group(1))}")',
            ),
            (
                r'\brequire\s+(["\'])([^"\']+)\1',
                lambda m: f'_require("{self._normalize_module_name(m.group(2))}")',
            ),
            (
                r'\brequire\s+\[\[([^\]]+)\]\]',
                lambda m: f'_require("{self._normalize_module_name(m.group(1))}")',
            ),
        ]

        for pattern, replacement in patterns:
            result = re.sub(pattern, replacement, result)

        return result

    def _normalize_module_name(self, module_name: str) -> str:
        """
        Normalize a module name by replacing dots with slashes.
        
        :param module_name: Original module name (e.g., 'utils.log')
        :return: Normalized module name (e.g., 'utils/log')
        """
        return module_name.replace(".", "/")

    def _indent_code(self, code: str, spaces: int = 4) -> str:
        """
        Add indentation to each line of code.
        
        :param code: Multi-line code string
        :param spaces: Number of spaces for indentation
        :return: Indented code
        """
        indent = " " * spaces
        lines = code.split("\n")
        indented_lines = [
            indent + line if line.strip() else line for line in lines]
        return "\n".join(indented_lines)

    def _wrap_module(self, file_path: Path) -> str:
        """
        Wrap a module file's content in the module template.
        
        :param file_path: Path to the module file
        :return: Wrapped module code
        """
        content = self._read_file_content(file_path)
        rewritten = self._rewrite_requires(content)
        indented = self._indent_code(rewritten)
        module_name = self._path_to_module_name(file_path)

        return MODULE_TEMPLATE.format(
            module_name=module_name,
            module_code=indented,
        )

    def _wrap_entry(self) -> str:
        """
        Wrap the entry script in the entry template.
        
        :return: Wrapped entry code
        """
        content = self._read_file_content(self.entry_script)
        rewritten = self._rewrite_requires(content)
        indented = self._indent_code(rewritten)

        return ENTRY_TEMPLATE.format(entry_code=indented)

    def _generate_bundled_script(self) -> str:
        """
        Generate the complete bundled script.
        
        :return: Complete bundled Lua script as string
        """
        parts: list[str] = []

        runtime = RUNTIME_TEMPLATE.format(
            timestamp=datetime.now().isoformat(),
            entry_name=self.entry_script.name,
        )
        parts.append(runtime)

        for dep_path in self.dependencies:
            if dep_path.exists():
                wrapped_module = self._wrap_module(dep_path)
                parts.append(wrapped_module)

        entry_code = self._wrap_entry()
        parts.append(entry_code)

        return "\n".join(parts)


def bundle_sources(
    entry_script: str,
    dependencies: "Sequence[str]",
    output_path: str | None = None,
) -> str:
    """
    Bundle Lua scripts into a single file.
    
    Convenience function that creates a SourceBundler and calls bundle().
    
    :param entry_script: Absolute path to the entry Lua script
    :param dependencies: List of absolute paths to dependency files
    :param output_path: Output file path, or None to create a temp file
    :return: Absolute path to the generated script
    """
    bundler = SourceBundler(entry_script, dependencies)
    return bundler.bundle(output_path)
