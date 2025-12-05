"""
Logging system for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides a centralized logging system that persists logs
to disk using simpsave and provides query functionality.

:author: WaterRun
:file: logger.py
:date: 2025-12-05
"""

from datetime import datetime
from enum import StrEnum
from typing import Any, TypedDict

import simpsave as ss


class LogLevel(StrEnum):
    """Log level enumeration."""
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    SUCCESS = "success"


class LogEntry(TypedDict):
    """Type definition for a log entry."""
    timestamp: str
    level: str
    source: str
    action: str
    message: str
    details: dict[str, Any]


_LOG_KEY = "luainstaller_logs"
_LOG_FILE = ":ss:luainstaller_logs.json"
_MAX_LOGS = 1000


def log(
    log_level: LogLevel | str,
    source: str,
    action: str,
    message: str,
    **details: Any
) -> None:
    """
    Log an event to the persistent log store.
    
    :param log_level: Log level (debug, info, warning, error, success)
    :param source: Source of the log (e.g., 'cli', 'gui', 'api')
    :param action: Action being performed (e.g., 'build', 'analyze')
    :param message: Human-readable message
    :param details: Additional key-value details to store
    """
    
    entry: LogEntry = {
        "timestamp": datetime.now().isoformat(),
        "level": str(log_level),
        "source": source,
        "action": action,
        "message": message,
        "details": details,
    }
    
    try:
        existing: list[LogEntry] = []
        
        try:
            if ss.has(_LOG_KEY, file=_LOG_FILE):
                loaded = ss.read(_LOG_KEY, file=_LOG_FILE)
                if isinstance(loaded, list):
                    existing = loaded
        except FileNotFoundError:
            existing = []
        
        existing.append(entry)
        
        if len(existing) > _MAX_LOGS:
            existing = existing[-_MAX_LOGS:]
        
        ss.write(_LOG_KEY, existing, file=_LOG_FILE)
    except Exception:
        ...


def get_logs(
    limit: int | None = None,
    level: LogLevel | str | None = None,
    source: str | None = None,
    action: str | None = None,
    descending: bool = True,
) -> list[LogEntry]:
    """
    Retrieve logs from persistent storage with optional filtering.
    
    :param limit: Maximum number of logs to return
    :param level: Filter by log level
    :param source: Filter by source
    :param action: Filter by action
    :param descending: Sort by timestamp descending (newest first)
    :return: List of log entries
    """
    
    try:
        try:
            if not ss.has(_LOG_KEY, file=_LOG_FILE):
                return []
        except FileNotFoundError:
            return []
        
        logs: list[LogEntry] = ss.read(_LOG_KEY, file=_LOG_FILE)
        
        if not isinstance(logs, list):
            return []
        
        if level is not None:
            level_str = str(level)
            logs = [e for e in logs if e.get("level") == level_str]
        
        if source is not None:
            logs = [e for e in logs if e.get("source") == source]
        
        if action is not None:
            logs = [e for e in logs if e.get("action") == action]
        
        logs.sort(key=lambda x: x.get("timestamp", ""), reverse=descending)
        
        if limit is not None and limit > 0:
            logs = logs[:limit]
        
        return logs
    
    except Exception:
        return []


def clear_logs() -> bool:
    """
    Clear all stored logs.
    
    :return: True if successful, False otherwise
    """
    
    try:
        ss.write(_LOG_KEY, [], file=_LOG_FILE)
        return True
    except Exception:
        return False


def log_error(source: str, action: str, message: str, **details: Any) -> None:
    """Log an error message."""
    log(LogLevel.ERROR, source, action, message, **details)


def log_success(source: str, action: str, message: str, **details: Any) -> None:
    """Log a success message."""
    log(LogLevel.SUCCESS, source, action, message, **details)