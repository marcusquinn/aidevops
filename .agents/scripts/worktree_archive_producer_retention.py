#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Evidence-based expiry for producer recovery archives (GH#36470).

A producer archive may be the only copy of work from a removed worktree, so its
pin ends only on evidence: the source and its Git registration are gone, the
journal records a completed capture, and no `.keep` exists. An empty delta
(HEAD at the recorded base, nothing staged, unstaged or untracked) preserves
nothing and expires at once; any other archive expires after the producer TTL.
The size cap never removes a producer archive; it only counts it.
"""

import datetime
import json
import os
import shutil

from worktree_recovery_migration_state import load, manifest_digest
from worktree_recovery_producer import SCHEMA, journal_for_archive, operation_lock


PIN = ".aidevops-archive-pin"
KEEP = ".keep"
EMPTY_ARTIFACTS = {"diff.patch", "staged.patch", "untracked-files.txt"}
DEFAULT_TTL_DAYS = 30


def empty_delta(manifest):
    """True only when the manifest itself proves there is nothing to restore."""
    artifacts = manifest.get("artifacts")
    head = manifest.get("head_sha")
    return (manifest.get("capture_policy") == "git-only"
            and manifest.get("dirty_state") == "clean"
            and isinstance(head, str) and len(head) >= 40 and head == manifest.get("base_sha")
            and isinstance(artifacts, list) and bool(artifacts)
            and all(isinstance(item, dict) and item.get("size") == 0
                    and item.get("name") in EMPTY_ARTIFACTS for item in artifacts))


def eligibility(directory, record, manifest, created, now, ttl_days):
    """Return the expiry reason, or None while the archive must be kept."""
    if record.get("archive") != str(directory) or record.get("manifest_sha256") != manifest_digest(directory):
        raise ValueError("producer journal does not match archive")
    git_only = record["source"].get("capture_policy") == "git-only"
    if record.get("phase") != ("archived" if git_only else "verified"):
        return None
    if record.get("source_removal_outcome") not in ("removed", "pending"):
        return None
    source = record["source"]["identity"]
    # "pending" journals whose source was retired by another path carry the
    # same evidence check(removed=True) records: path and registration gone.
    if os.path.lexists(source["path"]) or os.path.lexists(source["admin"]):
        return None
    if os.path.lexists(directory / KEEP):
        return None
    if empty_delta(manifest):
        return "empty-delta"
    if (now - created).days >= ttl_days:
        return "ttl"
    return None


def inspect(root, directory, now, ttl_days):
    """Return (entry, reason); entry carries the exact pin bytes to re-check."""
    for path in (directory, *directory.parents):
        if path == root:
            break
        if path.is_symlink():
            raise ValueError("symlinked archive path")
    pin = directory / PIN
    if pin.is_symlink() or not pin.is_file():
        raise ValueError("producer archive without regular pin")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("symlinked manifest")
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    created = datetime.datetime.fromisoformat(manifest["created_at"].replace("Z", "+00:00"))
    if created.tzinfo is None or created > now:
        raise ValueError("invalid archive creation time")
    record = load(journal_for_archive(directory), SCHEMA)
    reason = eligibility(directory, record, manifest, created, now, ttl_days)
    value = directory.lstat()
    size = sum(path.stat().st_size for path in directory.iterdir())
    entry = (created, size, directory, (value.st_dev, value.st_ino), raw, pin.read_bytes())
    return entry, reason


def entries(root, ttl_days, report):
    """Split producer archives into expirable entries and protected bytes."""
    now = datetime.datetime.now(datetime.timezone.utc)
    eligible, protected = [], 0
    for manifest_path in sorted(root.glob(".producer-archives/*/*/*/*/manifest.json")):
        directory = manifest_path.parent
        try:
            entry, reason = inspect(root, directory, now, ttl_days)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            report(f"kept\t{directory}\t{error}")
            continue
        if reason is None:
            protected += entry[1]
        else:
            eligible.append(entry)
            report(f"producer-eligible\t{directory}\t{reason}")
    return eligible, protected


def remove(target, entry, remove_verified):
    """Re-check evidence under the producer lock, remove, then retire the journal."""
    directory = entry[2]
    journal = journal_for_archive(directory)
    transaction = journal.parent
    if transaction.parent.is_symlink() or transaction.is_symlink():
        raise ValueError("symlinked producer transaction path")
    with operation_lock(transaction):
        manifest = json.loads(entry[4])
        record = load(journal, SCHEMA)
        now = datetime.datetime.now(datetime.timezone.utc)
        if eligibility(directory, record, manifest, entry[0], now, target.producer_ttl) is None:
            raise ValueError("producer expiry evidence changed")
        remove_verified(target.root, target.identity, entry, target.helper)
        # The archive was the only payload; the journal now describes nothing.
        # A crash before this point leaves a harmless orphan journal.
        shutil.rmtree(transaction)
    for parent in (directory.parent, directory.parents[1], directory.parents[2]):
        try:
            os.rmdir(parent)
        except OSError:
            break


def ttl_days(value):
    days = int(value) if value else DEFAULT_TTL_DAYS
    if days < 1:
        raise ValueError("producer TTL must be a positive number of days")
    return days
