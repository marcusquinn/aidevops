# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private, backed-up configuration writes; never touch attachment leases."""

import contextlib
import fcntl
import hashlib
import os
import stat
import tempfile
import time
from pathlib import Path

from tabby_session_config import SessionError


def snapshot(path):
    """Reject symlinks and non-owned files before reading configuration."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise SessionError("Configuration paths must not contain symlinks")
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SessionError("Configuration must be an owned regular file without hard links")
    if info.st_mode & 0o022:
        raise SessionError("Configuration must not be writable by other accounts")
    return path.read_bytes()


def replace(path, content):
    fd, name = tempfile.mkstemp(prefix=".aidevops-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def apply(changes, dry_run):
    """Serialize writers, preserve backups, and roll back a partial write."""
    changes = [(p, old, new) for p, old, new in changes if old != new]
    if not changes:
        print("No changes needed")
        return
    for path, _old, _new in changes:
        print(("Would update: " if dry_run else "Updating: ") + str(path))
    if dry_run:
        return
    with contextlib.ExitStack() as stack:
        for directory in sorted({p.parent for p, _old, _new in changes}):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            lock = directory / ".aidevops-tabby-hosts.lock"
            snapshot(lock)
            fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            stack.callback(os.close, fd)
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise SessionError("Host configuration lock must be private and owned")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SessionError("Host configuration is busy; retry after the other writer finishes") from None
        apply_locked(changes)


def preserve_backups(changes):
    for path, old, _new in changes:
        if snapshot(path) != old:
            raise SessionError("Configuration changed concurrently; retry")
        if old is None:
            continue
        # Keep backups outside .ssh so Include globs cannot load them.
        directory = Path.home() / ".local/state/aidevops/tabby-host-config/backups"
        digest = hashlib.sha256(str(path).encode()).hexdigest()[:16]
        backup = directory / (digest + "-" + str(time.time_ns()) + ".backup")
        snapshot(backup)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(old)
            stream.flush()
            os.fsync(stream.fileno())
        print("Backup: " + str(backup))


def rollback(applied):
    for path, old, new in reversed(applied):
        if snapshot(path) != new:
            raise SessionError("Configuration changed during rollback")
        if old is None:
            path.unlink()
        else:
            replace(path, old)


def apply_locked(changes):
    applied = []
    try:
        preserve_backups(changes)
        for path, old, new in changes:
            if snapshot(path) != old:
                raise SessionError("Configuration changed concurrently; retry")
            replace(path, new)
            applied.append((path, old, new))
    except (OSError, SessionError):
        try:
            rollback(applied)
        except (OSError, SessionError):
            raise SessionError("Partial configuration update; rollback incomplete; inspect private backups") from None
        raise SessionError("Configuration update failed; file contents restored; private backups retained") from None
