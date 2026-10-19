#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private durable journals and opaque provenance for legacy recovery migration.

These records preserve evidence; they never authorize retirement or expiry.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess  # nosec B404 -- resolved du, argv only; see allocated_bytes
import tempfile

from worktree_archive_snapshot import snapshot
from worktree_lifetime_archive import inode, require


SCHEMA = "aidevops.worktree-recovery-migration/v1"
METADATA = ".aidevops-worktree-recovery"


def private_directory(path):
    require(path.is_absolute() and path == path.resolve(), "migration:noncanonical-directory")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    observed = path.lstat()
    require(stat.S_ISDIR(observed.st_mode) and observed.st_uid == os.getuid()
            and stat.S_IMODE(observed.st_mode) == 0o700, "migration:nonprivate-directory")
    for directory in (path, *path.parents):
        sync_directory(directory)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish(path, value):
    require(not path.is_symlink(), "migration:symlinked-journal")
    descriptor, temporary = tempfile.mkstemp(prefix=".journal-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as handle:
            json.dump(value, handle, sort_keys=True, ensure_ascii=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
        sync_directory(path.parent.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def load(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        observed = os.fstat(handle.fileno())
        require(stat.S_ISREG(observed.st_mode) and observed.st_uid == os.getuid()
                and not stat.S_IMODE(observed.st_mode) & 0o077, "migration:unsafe-journal")
        payload = handle.read(4 * 1024 * 1024 + 1)
    require(len(payload) <= 4 * 1024 * 1024, "migration:oversized-journal")
    value = json.loads(payload)
    require(isinstance(value, dict) and value.get("schema") == SCHEMA, "migration:invalid-journal")
    return value


def opaque_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        observed = os.fstat(handle.fileno())
        require(stat.S_ISREG(observed.st_mode) and observed.st_uid == os.getuid(),
                "migration:unsupported-provenance-file")
        payload = handle.read(65537)
    require(len(payload) <= 65536, "migration:oversized-provenance-file")
    return {"hex": payload.hex(), "mode": stat.S_IMODE(observed.st_mode)}


def provenance(bucket, worktree):
    metadata = bucket / METADATA
    require(not metadata.is_symlink() and not (metadata / "admin").is_symlink(),
            "migration:symlinked-provenance")
    require({entry.name for entry in bucket.iterdir()} == {METADATA, worktree.name},
            "migration:unexpected-bucket-entry")
    entries = list(metadata.iterdir())
    require(len(entries) <= 64, "migration:oversized-provenance-inventory")
    values = {entry.name: opaque_file(entry) for entry in entries if entry.name != "admin"}
    # Live Git administration is preserved by git-admin.json. These path-bearing
    # files are historical evidence only: never install them in a restored repo.
    for name in ("commondir", "gitdir"):
        values[f"admin/{name}"] = opaque_file(metadata / "admin" / name)
    values["worktree/.git"] = opaque_file(worktree / ".git")
    require(sum(len(value["hex"]) for value in values.values()) <= 1024 * 1024,
            "migration:oversized-provenance-inventory")
    return values


def source_state(identity):
    bucket = Path(identity["bucket_path"])
    worktree = Path(identity["archive_path"])
    require(bucket == bucket.resolve(strict=True) and worktree.parent == bucket
            and worktree == worktree.resolve(strict=True), "migration:source-path-changed")
    return {"identity": identity, "bucket_inode": inode(bucket),
            "worktree_inode": inode(worktree), "provenance": provenance(bucket, worktree),
            "snapshot": snapshot(worktree, preserve_git_admin=True, include_ignored=True)}


def allocated_bytes(path):
    du = shutil.which("du")
    require(du is not None, "migration:du-unavailable")
    require(path.is_absolute(), "migration:noncanonical-size-path")
    result = subprocess.run(  # nosec B603 -- resolved du and an absolute path, argv only
        [str(Path(du).absolute()), "-sk", str(path)],
        check=True, capture_output=True, timeout=60)
    return int(result.stdout.split(b"\t", 1)[0]) * 1024


def manifest_digest(archive):
    path = archive / "manifest.json"
    require(path.is_file() and not path.is_symlink(), "migration:missing-manifest")
    return hashlib.sha256(path.read_bytes()).hexdigest()
