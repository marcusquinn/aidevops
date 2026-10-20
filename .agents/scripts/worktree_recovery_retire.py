#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Explicit operator-confirmed retirement of verified legacy migration sources."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess  # nosec B404 -- fixed local guard helper, argv only
import sys

from worktree_lifetime_archive import inode, require
from worktree_recovery_migrate import verify_archive
from worktree_recovery_legacy_policy import guards
from worktree_recovery_migration_state import SCHEMA, allocated_bytes, load, publish
from worktree_recovery_retirement_transaction import claim, fingerprint, remove_claimed


def receipt_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report(record):
    return {"state": record["phase"], "retired": record["phase"] == "retired",
            "bucket_bytes": record["bucket_bytes"], "archive_bytes": record["archive_bytes"],
            "confirmation_token": record["confirmation_token"],
            "transaction": record.get("container"), "archive": record["archive"]}


def make_plan(directory, migration, bucket, lock):
    path = directory / "retirement.json"
    require(not os.path.lexists(path), "retirement:plan-already-exists; inspect retire-status")
    verify_archive(migration, lock)
    guards(migration["source"]["identity"], bucket, lock)
    record = {"schema": SCHEMA, "kind": "retirement", "phase": "planned",
              "bucket": str(bucket), "bucket_inode": inode(bucket),
              "fingerprint": fingerprint(bucket), "archive": migration["archive"],
              "bucket_bytes": allocated_bytes(bucket),
              "archive_bytes": allocated_bytes(Path(migration["archive"])),
              "migration_digest": receipt_digest(directory / "journal.json")}
    verify_archive(migration, lock)
    token = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    record["confirmation_token"] = "sha256:" + token
    publish(path, record)
    return report(record)


def retire(directory, migration, bucket, token, lock):
    record = load(directory / "retirement.json")
    require(record["kind"] == "retirement" and record["bucket"] == str(bucket),
            "retirement:wrong-plan")
    require(token == record["confirmation_token"], "retirement:confirmation-mismatch")
    require(receipt_digest(directory / "journal.json") == record["migration_digest"],
            "retirement:migration-receipt-changed")
    if record["phase"] == "retired":
        return report(record)
    require(record["phase"] in ("planned", "claiming", "claimed", "removing"),
            "retirement:unknown-phase")
    unclaimed = record["phase"] == "planned"
    if record["phase"] == "claiming":
        unclaimed = not os.path.lexists(Path(record["container"]) / "bucket")
    verify_archive(migration, lock, check_source=unclaimed)
    guards(migration["source"]["identity"], bucket, lock)
    target = claim(directory, record, bucket)
    verify_archive(migration, lock, check_source=False)
    guards(migration["source"]["identity"], target, lock)
    remove_claimed(directory, record, target)
    return report(record)


def execute(arguments):
    bucket = Path(arguments.bucket)
    require(bucket.is_absolute() and bucket.name.startswith("aidevops-worktree-cleanup-"),
            "retirement:invalid-bucket")
    directory = bucket.parent / ".compact-migrations" / bucket.name
    require((directory / "journal.json").is_file(), "retirement:migration-receipt-missing")
    require(directory == directory.resolve(strict=True), "retirement:unsafe-journal-path")
    migration = load(directory / "journal.json")
    require(inode(directory) == migration["directory_inode"], "retirement:journal-directory-changed")
    require(migration["source"]["identity"]["bucket_path"] == str(bucket), "retirement:wrong-bucket")
    git_only = migration["source"].get("capture_policy") == "git-only"
    require(migration["phase"] == ("archived" if git_only else "verified"), "retirement:migration-incomplete")
    descriptor = os.open(directory / "lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), "retirement:unsafe-lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if arguments.action == "retire-plan":
            return make_plan(directory, migration, bucket, descriptor)
        if arguments.action == "retire-status":
            return report(load(directory / "retirement.json"))
        return retire(directory, migration, bucket, arguments.confirm, descriptor)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("retire-plan", "retire", "retire-status"))
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--confirm", default="")
    arguments = parser.parse_args()
    try:
        print(json.dumps(execute(arguments), sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "retirement:evidence-unavailable"
        print(json.dumps({"state": "incomplete", "reason": reason, "retired": False}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
