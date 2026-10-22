#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded retry observations and identity checks, never removal authority."""

import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import stat

from worktree_lifetime_archive import inode, require
from worktree_recovery_diagnostics import failure_details
from worktree_recovery_migration_state import load, opaque_file
from worktree_recovery_legacy_report import FIELDS as LEGACY_REPORT_FIELDS


def stamp(path):
    if not os.path.lexists(path):
        return None
    value = path.lstat()
    require(not stat.S_ISLNK(value.st_mode), "migration:source-path-changed")
    return [value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns]


def journal_identity(directory, bucket, identity):
    saved = load(directory / "journal.json")
    source = saved["source"]
    require(saved["directory_inode"] == inode(directory)
            and source["identity"]["bucket_path"] == str(bucket), "migration:reservation-changed")
    require(source.get("capture_policy") == "git-only"
            and source["identity"]["source_removal_outcome"] == "removed",
            "migration:incomplete-archived-copy")
    require(identity["bucket_inode"] in (None, source["bucket_inode"]), "migration:source-identity-conflict")
    identity["bucket_inode"] = source["bucket_inode"]
    identity["source"] = source
    archive = Path(saved["archive"]) if "archive" in saved else None
    if archive:
        require(archive == archive.resolve(), "migration:archive-path-changed")
        # Stat changes wake attempts; verification still hashes all bytes.
        # Never copy the transaction phase into retry.json.
        entries = list(islice(archive.iterdir(), 65))
        require(len(entries) <= 64, "migration:oversized-artifact-inventory")
        identity["artifacts"] = {p.name: stamp(p) for p in entries}
    return Path(source["identity"]["archive_path"]), Path(source["identity"]["common_path"])


def metadata_identity(root, bucket, identity):
    metadata = bucket / ".aidevops-worktree-recovery"
    require(metadata.is_dir() and not metadata.is_symlink(), "migration:incomplete-archived-copy")
    fields = (*LEGACY_REPORT_FIELDS, "head", "branch", "common-real",
              "storage-owner", "storage-class", "storage-policy", "storage-root")
    identity["metadata"] = {field: opaque_file(metadata / field) for field in fields}
    values = {key: bytes.fromhex(value["hex"]).decode().rstrip("\n")
              for key, value in identity["metadata"].items()}
    expected = {"format": "aidevops-worktree-recovery-v2", "archive-complete": "aidevops-worktree-recovery-v2",
                "source-removal-outcome": "removed", "storage-owner": "framework", "storage-class": "recovery",
                "storage-policy": "manual-review", "storage-root": str(root)}
    require(all(values[key] == value for key, value in expected.items()), "migration:incomplete-archived-copy")
    entries = list(islice(bucket.iterdir(), 3))
    worktrees = [entry for entry in entries if entry != metadata]
    require(len(entries) == 2 and len(worktrees) == 1 and worktrees[0].is_dir(), "migration:incomplete-archived-copy")
    return worktrees[0], Path(values["common-real"])


def observe(root, name, directory):
    """Bounded metadata only: no Git, recursive sizes, process scans or payload IO."""
    bucket = root / name
    identity = {"root_inode": inode(root), "bucket_inode": inode(bucket) if bucket.is_dir() else None}
    code = None
    try:
        require(not bucket.is_symlink(), "migration:source-path-changed")
        if os.path.lexists(directory / "journal.json"):
            worktree, common = journal_identity(directory, bucket, identity)
        else:
            worktree, common = metadata_identity(root, bucket, identity)
        # Ordinary HEAD/index replacement is cheap; nested edits may need
        # explicit retry, never a recursive scan.
        metadata = bucket / ".aidevops-worktree-recovery"
        require(not metadata.is_symlink() and not (metadata / "admin").is_symlink(), "migration:source-path-changed")
        require(worktree.parent == bucket and common.is_absolute(), "migration:source-path-changed")
        identity["worktree"] = stamp(worktree)
        identity["base_inode"] = inode(common) if common.is_dir() else None
        identity["admin"] = {key: stamp(metadata / "admin" / key) for key in ("HEAD", "index")}
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        code = failure_details(error, "eligibility")["failure_code"]
        identity["observation_error"] = code
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return digest, code


def already_completed(directory, bucket):
    path = directory / "retirement.json"
    if not os.path.lexists(path):
        return False
    retired = load(path)
    if retired.get("phase") != "retired":
        return False
    migration = load(directory / "journal.json")
    valid_receipt = retired.get("kind") == "retirement" and retired.get("authority") == "verified-git-changes/v1"
    valid_bucket = retired["bucket"] == str(bucket) and not os.path.lexists(bucket)
    valid_source = retired["bucket_inode"] == migration["source"]["bucket_inode"]
    valid_archive = retired["archive"] == migration["archive"] and migration["directory_inode"] == inode(directory)
    require(all((valid_receipt, valid_bucket, valid_source, valid_archive)), "migration:completion-identity-conflict")
    return True
