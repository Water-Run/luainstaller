"""
srlua binary package for luainstaller.
https://github.com/Water-Run/luainstaller

This package contains precompiled srlua binaries for Windows and Linux.

:author: WaterRun
:file: srlua/__init__.py
:date: 2025-12-15
"""

from pathlib import Path


SRLUA_DIR = Path(__file__).parent

WINDOWS_DIR = SRLUA_DIR / "windows"
LINUX_DIR = SRLUA_DIR / "linux"


__all__ = ["SRLUA_DIR", "WINDOWS_DIR", "LINUX_DIR"]
