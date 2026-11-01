"""Stable, path-free refusal codes for worktree creation failures (GH#36370).

Git stderr and OSError text carry local paths that end up pasted into issues;
only the matched code is ever emitted, never the underlying message.
"""

from __future__ import annotations

from collections.abc import Callable
import re
import sqlite3
import subprocess  # nosec B404 # exception types only; no process is started here

CREATION_OPERATIONS = frozenset({"create-worktree", "admit-session", "enroll"})
_REFUSAL_CODE = re.compile(r"[a-z0-9][a-z0-9-]{0,99}")
_SQLITE_CODES = (
    ("database is locked", "database-locked"),
    ("database table is locked", "database-locked"),
    ("no such table", "no-such-table"),
    ("no such column", "no-such-column"),
    ("readonly database", "database-readonly"),
    ("disk i/o error", "disk-io-error"),
    ("unable to open database", "database-unopenable"),
    ("database disk image is malformed", "database-malformed"),
    ("database or disk is full", "database-full"),
)
_GIT_CODES = (
    ("is already used by worktree", "ref-already-checked-out"),
    ("is already checked out", "ref-already-checked-out"),
    ("already exists", "path-already-exists"),
    ("invalid reference", "invalid-ref"),
    ("not a valid object name", "invalid-ref"),
    ("not a valid branch name", "invalid-ref"),
    ("locked", "worktree-locked"),
)


def _git_code(error: Exception) -> str:
    raw = getattr(error, "stderr", None)
    stderr = (raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw or "")).casefold()
    return next((code for needle, code in _GIT_CODES if needle in stderr), "git-worktree-add-failed")


def _sqlite_code(error: Exception) -> str:
    message = str(error).casefold()
    code = next((code for needle, code in _SQLITE_CODES if needle in message), None)
    return code or "sqlite-" + re.sub(r"(?<!^)(?=[A-Z])", "-", type(error).__name__).lower()


def _value_code(error: Exception) -> str | None:
    text = str(error)
    return text if _REFUSAL_CODE.fullmatch(text) else None


_HANDLERS: tuple[tuple[type[Exception], Callable[[Exception], str | None]], ...] = (
    (subprocess.TimeoutExpired, lambda _error: "git-timeout"),
    (subprocess.CalledProcessError, _git_code),
    (sqlite3.Error, _sqlite_code),
    (ValueError, _value_code),
)


def refusal_code(error: Exception, operation: str) -> str | None:
    """Stable cause of a creation-path refusal, or None outside creation operations."""
    handler = next((handler for kind, handler in _HANDLERS if isinstance(error, kind)), None)
    if handler is None or operation not in CREATION_OPERATIONS:
        return None
    return handler(error)
