#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private retirement claims; original public names are never removal targets."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

from worktree_lifetime_archive import inode, require
from worktree_recovery_migration_state import publish, sync_directory


def file_digest(path, observed):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode), "retirement:unsupported-file-type")
        require((before.st_dev, before.st_ino) == (observed.st_dev, observed.st_ino),
                "retirement:file-replaced")
        digest = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(handle.fileno())
        require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns), "retirement:file-changed")
        return digest.hexdigest()


def fingerprint(root):
    """Hash physical contents without resolving the relocated Git administration."""
    entries = []
    pending = [root]
    while pending:
        path = pending.pop()
        value = path.lstat()
        require(value.st_uid == os.geteuid(), "retirement:foreign-owner")
        require(not os.listxattr(path, follow_symlinks=False), "retirement:unsupported-metadata")
        kind = stat.S_IFMT(value.st_mode)
        payload = ""
        if stat.S_ISDIR(value.st_mode):
            pending.extend(sorted(path.iterdir()))
        elif stat.S_ISREG(value.st_mode):
            payload = file_digest(path, value)
        elif stat.S_ISLNK(value.st_mode):
            payload = os.readlink(path)
        else:
            raise ValueError("retirement:unsupported-file-type")
        entries.append((str(path.relative_to(root)), kind, stat.S_IMODE(value.st_mode),
                        value.st_uid, value.st_gid, payload))
    return hashlib.sha256(json.dumps(sorted(entries), ensure_ascii=True).encode()).hexdigest()


def claim(directory, record, bucket):
    journal = directory / "retirement.json"
    if record["phase"] == "planned":
        container = Path(tempfile.mkdtemp(prefix="retirement-", dir=directory))
        record.update(phase="claiming", container=str(container), container_inode=inode(container))
        publish(journal, record)
    container = Path(record["container"])
    require(container.parent == directory and not container.is_symlink(), "retirement:unsafe-container")
    require(inode(container) == record["container_inode"], "retirement:container-replaced")
    target = container / "bucket"
    if record["phase"] == "claiming" and not os.path.lexists(target):
        require(inode(bucket) == record["bucket_inode"], "retirement:bucket-replaced")
        require(fingerprint(bucket) == record["fingerprint"], "retirement:source-drift")
        os.rename(bucket, target)
        sync_directory(bucket.parent)
        sync_directory(container)
    require({p.name for p in container.iterdir()} == {"bucket"}, "retirement:incomplete-transaction")
    require(not target.is_symlink() and inode(target) == record["bucket_inode"],
            "retirement:claimed-bucket-replaced")
    require(fingerprint(target) == record["fingerprint"], "retirement:claimed-content-drift")
    record["phase"] = "claimed"
    publish(journal, record)
    return target


def remove_claimed(directory, record, target):
    """Caller holds producer and migration locks; private containers exclude writers."""
    require(shutil.rmtree.avoids_symlink_attacks, "retirement:safe-removal-unavailable")
    descriptor = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        observed = os.fstat(descriptor)
        require(f"{observed.st_dev}:{observed.st_ino}" == record["container_inode"],
                "retirement:container-replaced")
        require(inode(target) == record["bucket_inode"], "retirement:claimed-bucket-replaced")
        require(fingerprint(target) == record["fingerprint"], "retirement:claimed-content-drift")
        record["phase"] = "removing"
        publish(directory / "retirement.json", record)
        shutil.rmtree("bucket", dir_fd=descriptor)
        os.fsync(descriptor)
        record["phase"] = "retired"
        publish(directory / "retirement.json", record)
    finally:
        os.close(descriptor)
