#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Retention for verified compact archives, never full recovery worktrees."""

import collections
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

from worktree_archive_git import base_import_timeout
from worktree_archive_process import run_bounded, termination_as_exit
from worktree_archive_scratch import sweep_root


PIN = ".aidevops-archive-pin"
RETENTION_ERRORS = (OSError, ValueError, KeyError, TypeError, AttributeError,
                    subprocess.TimeoutExpired)
# A verification needs the base import budget plus restore checks. Starting
# one with less time left only produces a killed, wasted attempt.
MIN_VERIFY_SECONDS = 60
DEADLINE = None  # time.monotonic() bound for the whole pass, or None.


class Deferred(Exception):
    """The pass budget cannot fit another verification; resume next pass."""


def ensure_budget():
    """Raise Deferred before any change when the pass cannot fit a verification."""
    if DEADLINE is not None and DEADLINE - time.monotonic() < MIN_VERIFY_SECONDS:
        raise Deferred("pass budget exhausted")


def verify_timeout():
    """Per-verification budget, clipped to the pass deadline (never raises)."""
    budget = base_import_timeout() + 300
    if DEADLINE is None:
        return budget
    return max(1, min(budget, DEADLINE - time.monotonic()))


def identity(path):
    value = path.lstat()
    return value.st_dev, value.st_ino


def verify(helper, directory):
    bash = shutil.which("bash")
    if bash is None:
        raise FileNotFoundError("archive verification requires bash")
    # The caller supplies the local helper; archive data is only a path argument.
    # run_bounded() terminates gracefully so the verifier removes its scratch.
    result = run_bounded(
        [str(Path(bash).absolute()), str(helper), "verify", str(directory)],
        verify_timeout(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError("archive verification failed")


def inspect(root, directory):
    """Reject aliases, pins and malformed metadata from cheap local state only.

    Full verification is expensive (it imports the base graph), so it runs
    only for archives selected for removal, never for every archive.
    """
    for path in (directory, *directory.parents):
        if path == root:
            break
        if path.is_symlink():
            raise ValueError("symlinked archive path")
    if os.path.lexists(directory / PIN):
        raise ValueError("pinned archive")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("symlinked manifest")
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    created = datetime.datetime.fromisoformat(manifest["created_at"].replace("Z", "+00:00"))
    if created.tzinfo is None or created > datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("invalid archive creation time")
    size = sum(path.stat().st_size for path in directory.iterdir())
    return created, size, directory, identity(directory), raw


def remove_verified(root, root_identity, entry, helper):
    """Anchor removal to no-follow directory descriptors, not mutable ancestor paths."""
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
        raise ValueError("safe directory removal unavailable on this platform")
    directory, expected_identity, expected_manifest = entry[2:]
    descriptors = []
    original_cwd = os.open(".", os.O_RDONLY)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open(root, flags)
        descriptors.append(descriptor)
        value = os.fstat(descriptor)
        if (value.st_dev, value.st_ino) != root_identity:
            raise ValueError("archive root changed")
        parts = directory.relative_to(root).parts
        for name in parts:
            descriptor = os.open(name, flags, dir_fd=descriptor)
            descriptors.append(descriptor)
        os.fchdir(descriptor)
        if identity(Path(".")) != expected_identity:
            raise ValueError("archive identity changed")
        if os.path.lexists(PIN) or Path("manifest.json").read_bytes() != expected_manifest:
            raise ValueError("archive policy or manifest changed")
        # Atomically claim the name into a private transaction directory before
        # verification/removal. A replacement at the old public name is never
        # deleted. Pins must be set before claiming; recheck held-open writers too.
        transaction = ".prune-" + uuid.uuid4().hex
        os.mkdir(transaction, mode=0o700, dir_fd=descriptors[0])
        claimed_fd = os.open(transaction, flags, dir_fd=descriptors[0])
        parent_fd = descriptors[-2]
        descriptors.append(claimed_fd)
        os.rename(parts[-1], "archive", src_dir_fd=parent_fd, dst_dir_fd=claimed_fd)
        os.fchdir(claimed_fd)
        claimed = Path("archive")
        try:
            if identity(claimed) != expected_identity:
                raise ValueError("archive replaced while claiming")
            verify(helper, claimed)
            if (os.path.lexists(claimed / PIN) or
                    (claimed / "manifest.json").read_bytes() != expected_manifest):
                raise ValueError("archive policy or manifest changed during verification")
            shutil.rmtree(claimed)
            os.rmdir(transaction, dir_fd=descriptors[0])
        except Exception:
            print(f"retained-transaction\t{root / transaction}", file=sys.stderr)
            raise
    finally:
        os.fchdir(original_cwd)
        os.close(original_cwd)
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def candidate_entries(root):
    """Collect archives with valid metadata; malformed entries are kept."""
    entries = []
    for manifest_path in root.glob("*/*/*/manifest.json"):
        try:
            entries.append(inspect(root, manifest_path.parent))
        except RETENTION_ERRORS as error:
            print(f"kept\t{manifest_path.parent}\t{error}", file=sys.stderr)
    return sorted(entries, key=lambda entry: (entry[0], str(entry[2])))


Target = collections.namedtuple("Target", "root identity helper mode")


def attempt(target, entry):
    """Verify (and in apply mode remove) one candidate; True only on success."""
    ensure_budget()
    try:
        if target.mode == "apply":
            remove_verified(target.root, target.identity, entry, target.helper)
        else:
            verify(target.helper, entry[2])
    except RETENTION_ERRORS as error:
        print(f"kept\t{entry[2]}\t{error}", file=sys.stderr)
        return False
    print(f"{target.mode}\t{entry[2]}")
    return True


def prune(target, entries, days, limit):
    """Remove expired archives, then the oldest survivors above the size cap.

    Unverifiable archives are kept and do not count as freed space. Running
    out of pass budget defers the rest to the next pass; it is not a failure.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    expired = [entry for entry in entries if (now - entry[0]).days >= days]
    survivors = [entry for entry in entries if (now - entry[0]).days < days]
    survivor_total = sum(entry[1] for entry in survivors)
    failed = False
    try:
        for entry in expired:
            failed |= not attempt(target, entry)
        for entry in survivors:
            if survivor_total <= limit:
                break
            if attempt(target, entry):
                survivor_total -= entry[1]
            else:
                failed = True
    except Deferred as reason:
        print(f"deferred\t{reason}", file=sys.stderr)
    return int(failed)


def main():
    global DEADLINE
    root = Path(sys.argv[1]).resolve()
    days, raw_limit, mode = int(sys.argv[2]), sys.argv[3], sys.argv[4]
    helper = Path(sys.argv[5]).resolve()
    budget = int(sys.argv[6]) if len(sys.argv) > 6 else 0
    if mode not in ("apply", "dry-run") or budget < 0:
        raise SystemExit("invalid prune mode or budget")
    if budget:
        DEADLINE = time.monotonic() + budget
    units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
    limit = int(raw_limit[:-1]) * units[raw_limit[-1]] if raw_limit[-1] in units else int(raw_limit)
    if not root.is_dir():
        return 0
    # Dead verification scratch is derived data, never an archive: reclaim it
    # in both modes (GH#36468).
    for path in sweep_root(root):
        print(f"reclaimed-scratch\t{path}", file=sys.stderr)
    target = Target(root, identity(root), helper, mode)
    return prune(target, candidate_entries(root), days, limit)


if __name__ == "__main__":
    # An outer backstop timeout must reach the verifier as SIGTERM so it can
    # remove its scratch (run_bounded forwards it to the child group).
    with termination_as_exit():
        sys.exit(main())
