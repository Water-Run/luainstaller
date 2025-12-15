"""
Custom exception classes for luainstaller.
https://github.com/Water-Run/luainstaller

:author: WaterRun
:file: exceptions.py
:date: 2025-12-15
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
            reason,
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
            f"Circular dependency detected: {chain_str}",
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
            f"Use require('module_name') with a literal string.",
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
            f"This may indicate circular dependencies or an overly complex project.",
        )
        self.current_count = current_count
        self.limit = limit


class ModuleNotFoundError(DependencyAnalysisError):
    """
    Raised when a required module cannot be resolved to a file path.
    
    This occurs when the module is not found in any search path.
    """

    def __init__(
        self, module_name: str, script_path: str, searched_paths: list[str]
    ) -> None:
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
            f"Check if the module name is correct or if it needs to be installed.",
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
            f"C modules (.so, .dll, .dylib) are not supported by automatic "
            f"dependency analysis.\n"
            f"You may need to compile them manually or use --manual mode.",
        )
        self.module_name = module_name
        self.module_path = module_path


class CompilationError(LuaInstallerException):
    """
    Base class for compilation related errors.
    
    This occurs when the underlying compilation process fails.
    """

    ...


class EngineNotFoundError(CompilationError):
    """
    Raised when the specified engine is not found or not available.
    
    This occurs when the user specifies an invalid engine name or
    an engine that is not available on the current platform.
    """

    def __init__(self, engine_name: str, available_engines: list[str]) -> None:
        """
        Initialize the EngineNotFoundError.
        
        :param engine_name: The engine name that was not found
        :param available_engines: List of available engine names
        """
        super().__init__(
            f"Engine '{engine_name}' not found",
            f"Available engines: {', '.join(available_engines)}",
        )
        self.engine_name = engine_name
        self.available_engines = available_engines


class LuastaticNotFoundError(CompilationError):
    """
    Raised when luastatic command is not found in the system.
    
    User needs to install luastatic via: luarocks install luastatic
    """

    def __init__(self) -> None:
        super().__init__(
            "luastatic not found in system",
            "Please install it via: luarocks install luastatic",
        )


class SrluaNotFoundError(CompilationError):
    """
    Raised when srlua binaries are not found.
    
    This should not normally occur as srlua binaries are bundled
    with the package.
    """

    def __init__(self, engine_name: str) -> None:
        """
        Initialize the SrluaNotFoundError.
        
        :param engine_name: The srlua engine name that was not found
        """
        super().__init__(
            f"srlua binary for engine '{engine_name}' not found",
            "Please reinstall luainstaller package",
        )
        self.engine_name = engine_name


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
            "Please install a C compiler (gcc/clang/MinGW)",
        )
        self.compiler_name = compiler_name


class CompilationFailedError(CompilationError):
    """
    Raised when the compilation process fails.
    
    This occurs when the engine returns a non-zero exit code.
    """

    def __init__(
        self, command: str, return_code: int, stderr: str | None = None
    ) -> None:
        """
        Initialize the CompilationFailedError.
        
        :param command: The compilation command that failed
        :param return_code: The exit code from the engine
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
    
    This can happen if the engine succeeds but doesn't generate the
    expected executable file.
    """

    def __init__(self, expected_path: str) -> None:
        """
        Initialize the OutputFileNotFoundError.
        
        :param expected_path: The expected path of the output file
        """
        super().__init__(
            f"Output file not found: {expected_path}",
            "Compilation appeared to succeed but output file was not generated",
        )
        self.expected_path = expected_path
