"""Archive-specific policy on the shared read-only directory-chain checks."""

from __future__ import annotations

import os
from pathlib import Path

from .filesystem import FilesystemValidationError, checked_directory


def validate_archive_path(root: Path, archive: Path | None = None) -> None:
    """Allow owned 0755 roots/intermediates, but require a private archive leaf.

    Existing archive reason codes remain stable. Same-UID/admin actors are
    trusted; extended ACL models beyond POSIX mode bits are not evaluated.
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
