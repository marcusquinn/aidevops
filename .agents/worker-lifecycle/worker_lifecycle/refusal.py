"""Stable, path-free refusal codes for worktree creation (GH#36370) and
targeted retirement (GH#36494) failures.

Git stderr and OSError text carry local paths that end up pasted into issues;
only the matched code is ever emitted, never the underlying message.
"""

from __future__ import annotations

from collections.abc import Callable
import errno
import re
import sqlite3
import subprocess  # nosec B404 # exception types only; no process is started here

from .filesystem import FilesystemValidationError

CREATION_OPERATIONS = frozenset({"create-worktree", "admit-session", "enroll"})
RETIREMENT_OPERATIONS = frozenset({
    "cleanup-worktree", "retire-enrolled-only", "retire-foreign-worktree",
})
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
    # GH#37922: the EDQUOT/ENOSPC strerror text Git appends to write failures is
    # the only proof of exhaustion. A bare "unable to write" stays generic, and
    # these lead so path fragments such as "locked" cannot mask them.
    ("disk quota exceeded", "disk-quota-exceeded"),
    ("no space left on device", "disk-full"),
    ("is already used by worktree", "ref-already-checked-out"),
    ("is already checked out", "ref-already-checked-out"),
    ("a branch named", "branch-already-exists"),
    ("already exists", "path-already-exists"),
    ("invalid reference", "invalid-ref"),
    ("not a valid object name", "invalid-ref"),
    ("not a valid branch name", "invalid-ref"),
    ("locked", "worktree-locked"),
)
def _git_locked(error: Exception) -> bool:
    raw = getattr(error, "stderr", None)
    stderr = (raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw or "")).casefold()
    # Git appends arbitrary lock reasons after the primary lock diagnostic.
    diagnostic = stderr.partition("\n")[0]
    lock_pattern = r"\bis locked\b|:locked\b|\bcannot (?:move|remove) a locked working tree\b"
    return bool(re.search(lock_pattern, diagnostic))


def _git_code(error: Exception) -> str:
    raw = getattr(error, "stderr", None)
    stderr = (raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw or "")).casefold()
    return next((code for needle, code in _GIT_CODES if needle in stderr), "git-worktree-add-failed")


def _sqlite_code(error: Exception) -> str:
    message = str(error).casefold()
    code = next((code for needle, code in _SQLITE_CODES if needle in message), None)
    return code or "sqlite-" + re.sub(r"(?<!^)(?=[A-Z])", "-", type(error).__name__).lower()


_CATEGORY_TERMS = (
    ("contention", ("locked", "busy")),
    ("capacity", ("full", "too big", "capacity", "journal-event-limit-reached")),
    ("permission", ("readonly", "read-only", "unable to open", "permission", "authorization")),
    ("schema", ("no such", "malformed", "not a database", "schema", "unsupported", "has no column")),
)
_ERRNO_CATEGORY = {
    errno.EAGAIN: "contention", errno.EBUSY: "contention", errno.ENOSPC: "capacity",
    errno.EDQUOT: "capacity", errno.EACCES: "permission", errno.EPERM: "permission",
    errno.EROFS: "permission",
}


def _os_category(error: OSError) -> str | None:
    if isinstance(error, BlockingIOError):
        return "contention"
    if isinstance(error, PermissionError):
        return "permission"
    return _ERRNO_CATEGORY.get(error.errno) if error.errno is not None else None


def failure_category(error: BaseException) -> str | None:
    """Sanitized class of a registry failure: contention, schema, capacity or permission.

    Only the fixed label is returned; message text, SQL and paths never leave here.
    """
    if isinstance(error, FilesystemValidationError) and isinstance(error.__cause__, OSError):
        return failure_category(error.__cause__)
    if isinstance(error, OSError):
        return _os_category(error)
    if not isinstance(error, (sqlite3.Error, ValueError)):
        return None
    message = str(error).casefold()
    return next((label for label, terms in _CATEGORY_TERMS if any(term in message for term in terms)), None)


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
    if isinstance(error, sqlite3.Error) and operation not in CREATION_OPERATIONS:
        # GH#36794: cleanup/retire paths report the same stable SQLite code.
        return _sqlite_code(error)
    if operation in RETIREMENT_OPERATIONS:
        # Never expose Git stderr: it may contain private paths or lock reasons.
        if isinstance(error, subprocess.CalledProcessError):
            return "worktree-locked" if _git_locked(error) else None
        return _value_code(error) if isinstance(error, ValueError) else None
    handler = next((handler for kind, handler in _HANDLERS if isinstance(error, kind)), None)
    if handler is None or operation not in CREATION_OPERATIONS:
        return None
    return handler(error)
