"""Archive-specific policy on the shared read-only directory-chain checks."""

from __future__ import annotations

import os
from pathlib import Path

from .filesystem import FilesystemValidationError, checked_directory


def create_archive_root(root: Path) -> None:
    """Create each missing root component 0700 regardless of a group-writable umask.

    `Path.mkdir(mode=..., parents=True)` applies the mode to the leaf only;
    parents get 0777 minus the umask. Existing directories are never modified.
    """
    missing = [candidate for candidate in (root, *root.parents) if not candidate.exists()]
    for candidate in reversed(missing):
        candidate.mkdir(mode=0o700, exist_ok=True)


def validate_archive_path(root: Path, archive: Path | None = None) -> None:
    """Allow owned 0755 roots/intermediates, but require a private archive leaf.

    Group-writable roots/intermediates pass only under the filesystem module's
    private-group or sealed-ancestor exceptions. Existing archive reason codes
    remain stable. Same-UID/admin actors are trusted.
    """
    target = root if archive is None else archive
    if archive == root:
        raise FilesystemValidationError("invalid-archive-path", target)
    try:
        with checked_directory(target, owned_root=root) as descriptor:
            if archive is not None and os.fstat(descriptor).st_mode & 0o077:
                raise FilesystemValidationError("archive-directory-not-private", target)
    except FilesystemValidationError as error:
        reason = error.reason.replace("filesystem", "archive", 1)
        if reason == error.reason:
            raise
        raise FilesystemValidationError(reason, error.path) from error
    except OSError as error:
        path = Path(error.filename) if error.filename else target
        raise FilesystemValidationError("archive-path-unavailable", path) from error
