#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Sweep manifest-less producer captures under their existing operation locks."""

import os
from pathlib import Path
import re
import shutil
import stat
import subprocess  # nosec B404 -- exception classification only
import sys

from worktree_lifetime_archive import inode, require
from worktree_recovery_migration_state import load


PARTIAL_PHASES = ("reserved", "capturing")
PIN = ".aidevops-archive-pin"


def partial_captures(output):
    """Find unpinned, manifest-less captures in the exact three-level layout."""
    found = []
    levels = [[output]]
    for _depth in range(3):
        children = []
        for parent in levels[-1]:
            children.extend(entry for entry in sorted(parent.iterdir())
                            if entry.is_dir() and not entry.is_symlink())
        levels.append(children)
    for capture_dir in levels[-1]:
        if not os.path.lexists(capture_dir / "manifest.json") and not os.path.lexists(capture_dir / PIN):
            found.append(capture_dir)
    return found


def source_intact(record):
    """Require recorded content evidence, including untracked files, before cleanup."""
    from worktree_recovery_producer import source_state
    saved = record["source"]
    baseline = saved.get("snapshot", {})
    policy = saved.get("capture_policy", "preserve-v1")
    schemas = (3, 4) if policy == "git-only" else (1,)
    if not isinstance(baseline, dict) or baseline.get("schema") not in schemas:
        return False
    try:
        source = Path(saved["identity"]["path"])
        return source_state(source, policy, baseline["schema"]) == saved
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def remove_partial(output, capture_dir):
    """Remove one partial and its empty layout parents, never ``output``."""
    observed = capture_dir.lstat()
    require(stat.S_ISDIR(observed.st_mode) and capture_dir.parent.parent.parent == output
            and not os.path.lexists(capture_dir / "manifest.json")
            and not os.path.lexists(capture_dir / PIN), "producer:partial-changed")
    shutil.rmtree(capture_dir)
    for parent in (capture_dir.parent, capture_dir.parent.parent):
        try:
            parent.rmdir()
        except OSError:
            break


def sweep_transaction(root, directory, apply, results):
    """Classify (and optionally remove) one reservation's partials under its lock."""
    from worktree_recovery_producer import SCHEMA
    record = load(directory / "journal.json", SCHEMA)
    if record.get("phase") not in PARTIAL_PHASES:
        return
    output = root / ".producer-archives" / directory.name
    require(record["directory_inode"] == inode(directory) and record["output"] == str(output)
            and output == output.resolve(strict=True) and record["output_inode"] == inode(output),
            "producer:reservation-changed")
    partials = partial_captures(output)
    if partials and not source_intact(record):
        results.extend(("retained:source-changed", path) for path in partials)
        return
    for path in partials:
        if apply:
            remove_partial(output, path)
        results.append(("removed" if apply else "would-remove", path))


def transaction_directory(directory):
    """Accept only real transaction directories with regular, non-symlink journals."""
    if not re.fullmatch(r"[0-9a-f]{64}", directory.name):
        return False
    if directory.is_symlink() or not directory.is_dir():
        return False
    journal = directory / "journal.json"
    return not journal.is_symlink() and journal.is_file()


def sweep_directory(root, directory, apply):
    """Keep completed outcomes visible even when a later removal fails."""
    from worktree_recovery_producer import operation_lock
    results = []
    try:
        with operation_lock(directory):
            sweep_transaction(root, directory, apply, results)
    except BlockingIOError:
        print(f"busy\t{directory}", file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "producer:evidence-unavailable"
        print(f"retained:{reason}\t{directory}", file=sys.stderr)
        return 1
    finally:
        for outcome, path in results:
            print(f"{outcome}\t{path}", file=sys.stdout if outcome in ("removed", "would-remove") else sys.stderr)
    return 0


def sweep_partials(root, apply):
    """Sweep interrupted captures; retain changed sources and skip busy locks."""
    require(root.is_absolute(), "producer:unsafe-storage-root")
    transactions = root / ".producer-transactions"
    if not transactions.is_dir() or transactions.is_symlink():
        return 0
    root = root.resolve(strict=True)
    transactions = root / ".producer-transactions"
    status = 0
    for directory in sorted(transactions.iterdir()):
        if not transaction_directory(directory):
            continue
        if sweep_directory(root, directory, apply):
            status = 1
    return status
