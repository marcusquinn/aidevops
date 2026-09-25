#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Cache-filtered recovery copying and per-source archive reservations.

The caller holds the existing recovery producer lock. Incomplete reservations
are deliberately retained: retrying must not multiply snapshots or discard
possibly unique data from an interrupted copy.
"""

import filecmp
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import time
from typing import Set, Tuple

from worktree_recovery_cache_policy_common import (
    git_output,
    ordinary_directory,
    require,
    root_identity,
    safe_root,
)


ATTEMPT_SCHEMA = "aidevops.worktree-recovery-attempt/v1"
BUCKET_PREFIX = "aidevops-worktree-cleanup-"


def disposable_cache(source: Path, relative: str, git_bin: str) -> bool:
    """Distinguish user data from an unknown/failed Git query before copying."""
    deadline = int(time.time()) + 10
    ignored_rc, _ = git_output(
        git_bin, source, ["check-ignore", "-q", "--", relative], deadline
    )
    require(ignored_rc in (0, 1), "cache ignore evidence unavailable")
    if ignored_rc == 1:
        return False
    tracked_rc, tracked = git_output(
        git_bin, source, ["ls-files", "-z", "--", relative], deadline
    )
    require(tracked_rc == 0, "cache tracked-file evidence unavailable")
    return not tracked


def copy_without_caches(source: Path, destination: Path, git_bin: str) -> int:
    """Never materialize ignored, untracked allowlisted caches in a new copy."""
    require(not os.path.lexists(destination), "archive destination already exists")
    source = source.resolve()
    excluded: Set[Tuple[str, ...]] = set()

    def ignore(directory: str, names: list) -> list:
        relative = Path(directory).relative_to(source)
        result = []
        for name in names:
            parts = (relative / name).parts
            if safe_root("/".join(parts)) != parts:
                continue
            if ordinary_directory(source, parts) is None:
                continue
            if disposable_cache(source, "/".join(parts), git_bin):
                excluded.add(parts)
                result.append(name)
        return result

    try:
        shutil.copytree(source, destination, symlinks=True, ignore=ignore)
        # A tracked/ignore-rule change during the copy must not publish a lossy
        # archive. Unknown Git state also fails closed, preserving the source.
        for parts in excluded:
            require(
                disposable_cache(source, "/".join(parts), git_bin),
                "cache classification changed during archival",
            )
    except (OSError, shutil.Error) as error:
        raise ValueError("recovery copy failed") from error
    return 0


def validate_attempt(record: dict, source: Path, root: Path, identity: str) -> Path:
    """Validate one exact reservation; incomplete copies need operator review."""
    require(isinstance(record, dict), "invalid archive reservation")
    require(record.get("schema") == ATTEMPT_SCHEMA, "unknown archive reservation")
    require(record.get("source") == str(source), "archive source changed")
    require(record.get("identity") == identity, "archive source identity changed")
    bucket = Path(record.get("bucket", ""))
    require(bucket.parent == root, "archive bucket escaped recovery root")
    require(bucket.name.startswith(BUCKET_PREFIX), "unknown archive bucket")
    require(bucket.is_dir() and not bucket.is_symlink(), "archive bucket unavailable")
    metadata = bucket / ".aidevops-worktree-recovery"
    marker = metadata / "archive-complete"
    require(
        not metadata.is_symlink() and marker.is_file() and not marker.is_symlink(),
        "recovery-archive-incomplete: inspect existing attempt before retrying",
    )
    return bucket


def same_entry(source: Path, archived: Path) -> bool:
    """Compare data without following symlinks or trusting timestamp equality."""
    source_mode = source.lstat().st_mode
    archived_mode = archived.lstat().st_mode
    if source_mode != archived_mode:
        return False
    if stat.S_ISLNK(source_mode):
        return os.readlink(source) == os.readlink(archived)
    if stat.S_ISDIR(source_mode):
        return True
    if not stat.S_ISREG(source_mode):
        return False
    filecmp.clear_cache()
    return filecmp.cmp(source, archived, shallow=False)


def matching_copy(source: Path, archive: Path, git_bin: str) -> int:
    """Require current user data and index to be preserved before snapshot reuse."""

    def unreadable(error: OSError) -> None:
        raise error

    try:
        for directory, dirs, files in os.walk(
            source, followlinks=False, onerror=unreadable
        ):
            relative = Path(directory).relative_to(source)
            for name in list(dirs) + files:
                parts = (relative / name).parts
                if parts == (".git",):
                    continue
                if (
                    safe_root("/".join(parts)) == parts
                    and ordinary_directory(source, parts) is not None
                    and disposable_cache(source, "/".join(parts), git_bin)
                ):
                    dirs.remove(name)
                    continue
                require(
                    same_entry(source.joinpath(*parts), archive.joinpath(*parts)),
                    "source data changed since archival",
                )
        # Git status can refresh index stat caches without changing staged data.
        # Compare stages/flags and staged binary diffs, not volatile index bytes.
        for arguments in (
            ["ls-files", "--stage", "-v", "-z"],
            ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"],
        ):
            snapshots = []
            for tree in (source, archive):
                rc, raw = git_output(git_bin, tree, arguments, int(time.time()) + 10)
                require(rc == 0, "index evidence unavailable")
                snapshots.append(raw)
            require(snapshots[0] == snapshots[1], "source index changed since archival")
    except OSError as error:
        raise ValueError("source comparison unavailable") from error
    return 0


def reserve_archive(source: Path, root: Path, _git_bin: str) -> str:
    """Allow at most one unfinished attempt for an unchanged source identity."""
    source = source.resolve()
    root = root.resolve()
    identity = root_identity(source)
    require(identity is not None, "source identity unavailable")
    key = hashlib.sha256(f"{source}\0{identity}".encode()).hexdigest()
    reservation = root / f".archive-attempt-{key}.json"
    try:
        if os.path.lexists(reservation):
            require(not reservation.is_symlink(), "reservation is a symlink")
            record = json.loads(reservation.read_text(encoding="utf-8"))
            return str(validate_attempt(record, source, root, identity))
        # Reserve before allocating a bucket. Even a kill between allocation and
        # publication leaves a fail-closed reservation, not an unbounded retry.
        descriptor = os.open(reservation, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            bucket = tempfile.mkdtemp(prefix=BUCKET_PREFIX, dir=root)
            json.dump(
                {
                    "schema": ATTEMPT_SCHEMA,
                    "source": str(source),
                    "identity": identity,
                    "bucket": bucket,
                },
                output,
            )
            output.flush()
            os.fsync(output.fileno())
        return bucket
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(
            "recovery reservation unavailable; inspect before retry"
        ) from error
