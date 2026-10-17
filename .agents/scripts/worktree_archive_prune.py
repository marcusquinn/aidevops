#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Retention for verified compact archives, never full recovery worktrees."""

import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


PIN = ".aidevops-archive-pin"
RETENTION_ERRORS = (OSError, ValueError, KeyError, TypeError, AttributeError,
                    subprocess.TimeoutExpired)


def identity(path):
    value = path.lstat()
    return value.st_dev, value.st_ino


def verify(helper, directory):
    bash = shutil.which("bash")
    if bash is None:
        raise FileNotFoundError("archive verification requires bash")
    # The caller supplies the local helper; archive data is only a path argument.
    result = subprocess.run(  # nosec B603 -- resolved Bash, operator-owned helper, argv only
        [str(Path(bash).absolute()), str(helper), "verify", str(directory)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60, check=False)
    if result.returncode:
        raise ValueError("archive verification failed")


def inspect(root, directory, helper):
    """Reject aliases, pins, malformed metadata, and incomplete/unknown payloads."""
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
    verify(helper, directory)
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


def verified_entries(root, helper):
    """Collect eligible archives while retaining every unverifiable entry."""
    entries = []
    for manifest_path in root.glob("*/*/*/manifest.json"):
        try:
            entries.append(inspect(root, manifest_path.parent, helper))
        except RETENTION_ERRORS as error:
            print(f"kept\t{manifest_path.parent}\t{error}", file=sys.stderr)
    return entries


def select_expired(entries, days, limit):
    """Select expired entries, then oldest survivors exceeding the size cap."""
    now = datetime.datetime.now(datetime.timezone.utc)
    selected = {entry[2] for entry in entries if (now - entry[0]).days >= days}
    remaining = sorted((entry for entry in entries if entry[2] not in selected),
                       key=lambda entry: (entry[0], str(entry[2])))
    remaining_total = sum(entry[1] for entry in remaining)
    for entry in remaining:
        if remaining_total <= limit:
            break
        selected.add(entry[2])
        remaining_total -= entry[1]
    return selected


def prune_selected(root, root_identity, entries, helper, mode):
    """Apply or preview the selection, reporting failures without dropping guards."""
    failed = False
    for entry in entries:
        try:
            if mode == "apply":
                remove_verified(root, root_identity, entry, helper)
            print(f"{mode}\t{entry[2]}")
        except RETENTION_ERRORS as error:
            failed = True
            print(f"kept\t{entry[2]}\t{error}", file=sys.stderr)
    return int(failed)


def main():
    root = Path(sys.argv[1]).resolve()
    days, raw_limit, mode = int(sys.argv[2]), sys.argv[3], sys.argv[4]
    helper = Path(sys.argv[5]).resolve()
    if mode not in ("apply", "dry-run"):
        raise SystemExit("invalid prune mode")
    units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
    limit = int(raw_limit[:-1]) * units[raw_limit[-1]] if raw_limit[-1] in units else int(raw_limit)
    if not root.is_dir():
        return 0
    root_identity = identity(root)
    entries = verified_entries(root, helper)
    selected = select_expired(entries, days, limit)
    selected_entries = (entry for entry in entries if entry[2] in selected)
    return prune_selected(root, root_identity, selected_entries, helper, mode)


if __name__ == "__main__":
    sys.exit(main())
