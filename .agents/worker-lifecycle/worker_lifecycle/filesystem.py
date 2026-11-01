"""Read-only POSIX path checks and controlled local diagnostic fields.

Same-UID processes and administrators remain trusted. Extended ACL models that
grant access beyond mode bits are not evaluated. Never chmod or create paths.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
import os
from pathlib import Path
import stat


class FilesystemValidationError(ValueError):
    """A fixed reason code with separate operator-local filesystem context."""

    def __init__(self, reason: str, path: Path, *, violation: str = ""):
        super().__init__(reason)
        self.reason = reason
        self.path = path
        self.violation = violation


def filesystem_error_details(error: FilesystemValidationError) -> dict[str, object]:
    """Serialize only this known error, never raw exception or subprocess text."""
    details: dict[str, object] = {
        "reason": error.reason, "filesystem_path": str(error.path),
    }
    if error.violation:
        details["filesystem_violation"] = error.violation
    cause = error.__cause__
    if isinstance(cause, OSError) and cause.errno is not None:
        details["errno"] = cause.errno
    return details


def _check_directory(descriptor: int, path: Path, owned_root: Path | None) -> None:
    info = os.fstat(descriptor)
    inside = owned_root is not None and path.is_relative_to(owned_root)
    owners = (os.getuid(),) if inside else (0, os.getuid())
    if info.st_uid not in owners:
        raise FilesystemValidationError("filesystem-path-wrong-owner", path)
    sticky_ancestor = not inside and bool(info.st_mode & stat.S_ISVTX)
    if info.st_mode & 0o022 and not sticky_ancestor:
        raise FilesystemValidationError("filesystem-path-externally-writable", path)


def _check_path_scope(path: Path, owned_root: Path | None) -> None:
    for candidate in (path, owned_root):
        if candidate is not None:
            if not candidate.is_absolute() or ".." in candidate.parts:
                raise FilesystemValidationError("invalid-filesystem-path", candidate)
    if owned_root is not None and not path.is_relative_to(owned_root):
        raise FilesystemValidationError("invalid-filesystem-path", path)


@contextmanager
def checked_directory(path: Path, *, owned_root: Path | None = None) -> Iterator[int]:
    """Open and check the full chain, yielding its final directory descriptor.

    Ancestors allow root/current-user ownership and sticky system temp paths.
    At/below owned_root require current-user ownership and no external writes.
    Preserve OSError subclasses, notably FileNotFoundError used by initialization.
    """
    _check_path_scope(path, owned_root)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    current = Path(path.anchor)
    descriptor = os.open(current, flags)
    try:
        for component in (*path.parts[1:], None):
            _check_directory(descriptor, current, owned_root)
            if component is None:
                break
            current = current / component
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                error.filename = str(current)
                raise
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def _private_stat(path: Path) -> os.stat_result:
    try:
        with checked_directory(path.parent) as parent:
            return os.stat(path.name or ".", dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        raise  # Absence is an initialization/cursor signal, not invalid state.
    except OSError as error:
        component = Path(error.filename) if error.filename else path
        if not component.is_absolute():
            component = path
        raise FilesystemValidationError("filesystem-path-unavailable", component) from error


def validate_private_path(path: Path, *, directory: bool = False) -> None:
    """Check trusted ancestors and a private owned final file/directory.

    Parent directories need integrity, not 0700. Preserve the historical private
    state reason code; a separate violation identifies type, owner or permissions.
    """
    path = path.absolute()
    _check_path_scope(path, None)
    info = _private_stat(path)
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode):
        violation = "wrong-type"
    elif info.st_uid != os.getuid():
        violation = "wrong-owner"
    elif info.st_mode & 0o077:
        violation = "not-private"
    else:
        return
    raise FilesystemValidationError(
        "state-path-must-be-private-and-owned", path, violation=violation,
    )
