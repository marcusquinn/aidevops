"""Read-only archive path checks for preservation and destructive retirement."""

from __future__ import annotations

import os
from pathlib import Path
import stat


def _validate_directory(descriptor: int, current: Path, root: Path,
                        archive: Path | None) -> None:
    """Apply the ownership/mode policy to an already opened directory."""
    info = os.fstat(descriptor)
    inside = current.is_relative_to(root)
    owners = (os.getuid(),) if inside else (0, os.getuid())
    if info.st_uid not in owners:
        raise ValueError(f"archive-path-wrong-owner: {current}")
    sticky_ancestor = not inside and bool(info.st_mode & stat.S_ISVTX)
    if info.st_mode & 0o022 and not sticky_ancestor:
        raise ValueError(f"archive-path-externally-writable: {current}")
    if current == archive and info.st_mode & 0o077:
        raise ValueError(f"archive-directory-not-private: {current}")


def validate_archive_path(root: Path, archive: Path | None = None) -> None:
    """Check POSIX ownership/mode bits without requiring a private root.

    System ancestors may belong to root; sticky system temp directories are
    allowed above the archive root. The root and its descendants must belong to
    this user. Same-UID processes and the system administrator remain trusted.
    Extended ACL models that grant access beyond mode bits are not evaluated.
    No directories are created and no permissions are changed.
    """
    target = root if archive is None else archive
    for path in (root, target):
        if not path.is_absolute() or ".." in path.parts:
            raise ValueError(f"invalid-archive-path: {path}")
    if not target.is_relative_to(root) or archive == root:
        raise ValueError(f"invalid-archive-path: {target}")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    current = Path(target.anchor)
    descriptor = os.open(current, flags)
    try:
        for component in (*target.parts[1:], None):
            _validate_directory(descriptor, current, root, archive)
            if component is None:
                break
            current = current / component
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
    except OSError as error:
        raise ValueError(f"archive-path-unavailable: {current}: {error.strerror}") from error
    finally:
        os.close(descriptor)
