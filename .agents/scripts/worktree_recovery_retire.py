#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Confirmed manual or policy-bound automatic retirement of verified recovery copies."""

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
from worktree_recovery_migrate import archive_command
from worktree_archive_restore import RestorationProof
from worktree_recovery_legacy_policy import guards
from worktree_recovery_migration_state import SCHEMA, allocated_bytes, load, publish
from worktree_recovery_retirement_transaction import claim, source_fingerprint, remove_claimed
from worktree_recovery_timing import context as timing_context, operation, timed
from worktree_recovery_retry import failure_details


def receipt_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report(record):
    return {"state": record["phase"], "retired": record["phase"] == "retired",
            "bucket_bytes": record["bucket_bytes"], "archive_bytes": record["archive_bytes"],
            "confirmation_token": record["confirmation_token"],
            "transaction": record.get("container"), "archive": record["archive"]}


def restoration(directory, migration, record, lock, proofs):
    common = Path(migration["source"]["identity"]["common_path"]).resolve(strict=True)
    bucket = Path(record["bucket"])
    require(not common.is_relative_to(bucket), "retirement:base-inside-source")
    if record.get("container"):
        require(not common.is_relative_to(Path(record["container"])), "retirement:base-inside-claim")
    require(migration["source"].get("capture_policy") == "git-only",
            "retirement:legacy-restoration-proof-unavailable; source retained")
    key = migration["archive"]
    if key not in proofs:
        data = dict(migration, canonical_restore=record.get("canonical_restore"))

        def save(value):
            record["canonical_restore"] = value["canonical_restore"]
            publish(directory / "retirement.json", record)

        proofs[key] = RestorationProof(directory, data, lambda *args: archive_command(lock, *args), save)
    proofs[key].check()


@timed("source-state-comparison")
def source_matches(migration):
    from worktree_recovery_migration_state import source_state
    require(source_state(migration["source"]["identity"],
                         migration["source"].get("capture_policy") == "git-only",
                         migration["source"]["snapshot"].get("schema")) == migration["source"],
            "migration:source-drift")


@timed("safety-guards")
def guarded(identity, bucket, lock):
    return guards(identity, bucket, lock)


def make_plan(directory, migration, lock, automatic=False, proofs=None):
    bucket = Path(migration["source"]["identity"]["bucket_path"])
    path = directory / "retirement.json"
    proofs = {} if proofs is None else proofs
    source_matches(migration)
    guarded(migration["source"]["identity"], bucket, lock)
    record = {"schema": SCHEMA, "kind": "retirement", "phase": "planning",
              "bucket": str(bucket), "bucket_inode": inode(bucket),
              "fingerprint": source_fingerprint(bucket), "archive": migration["archive"],
              "bucket_bytes": allocated_bytes(bucket),
              "archive_bytes": allocated_bytes(Path(migration["archive"])),
              "migration_digest": receipt_digest(directory / "journal.json"),
              "confirmation_token": None if automatic else ""}
    if automatic:
        record["authority"] = "verified-git-changes/v1"
    if os.path.lexists(path):
        previous = load(path)
        require(previous["phase"] == "planning", "retirement:plan-already-exists; inspect retire-status")
        require(all(previous.get(key) == value for key, value in record.items()), "retirement:planning-drift")
        record = previous
    restoration(directory, migration, record, lock, proofs)
    source_matches(migration)
    record["phase"] = "planned"
    if automatic:
        automatic_policy(migration, bucket)
        record.update(authority="verified-git-changes/v1", confirmation_token=None)
        publish(path, record)
        return report(record)
    token = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    record["confirmation_token"] = "sha256:" + token
    publish(path, record)
    return report(record)


def retire(directory, migration, token, lock, proofs=None):
    bucket = Path(migration["source"]["identity"]["bucket_path"])
    record = load(directory / "retirement.json")
    automatic = token is None
    require((record.get("authority") == "verified-git-changes/v1") == automatic,
            "retirement:authority-mismatch")
    if automatic:
        automatic_policy(migration, bucket)
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
    proofs = {} if proofs is None else proofs
    restoration(directory, migration, record, lock, proofs)
    if unclaimed:
        source_matches(migration)
    guarded(migration["source"]["identity"], bucket, lock)
    target = claim(directory, record, bucket)
    restoration(directory, migration, record, lock, proofs)
    guarded(migration["source"]["identity"], target, lock)
    remove_claimed(directory, record, target)
    return report(record)


def automatic_policy(migration, bucket):
    source = migration["source"]
    identity = source["identity"]
    require(migration["phase"] == "archived" and source.get("capture_policy") == "git-only"
            and source["snapshot"].get("schema") in (3, 4),
            "retirement:automatic-requires-untracked-preservation")
    require(identity.get("source_removal_outcome") == "removed",
            "retirement:source-removal-incomplete")
    common = Path(identity["common_path"]).resolve(strict=True)
    require(not common.is_relative_to(bucket), "retirement:base-inside-source")


def automatic_retire(directory, migration, bucket, lock):
    automatic_policy(migration, bucket)
    proofs = {}
    if (not os.path.lexists(directory / "retirement.json")
            or load(directory / "retirement.json")["phase"] == "planning"):
        make_plan(directory, migration, lock, automatic=True, proofs=proofs)
    return retire(directory, migration, None, lock, proofs=proofs)


@operation("recovery-retirement")
def execute(arguments):
    bucket = Path(arguments.bucket)
    require(bucket.is_absolute() and bucket.name.startswith("aidevops-worktree-cleanup-"),
            "retirement:invalid-bucket")
    directory = bucket.parent / ".compact-migrations" / bucket.name
    require((directory / "journal.json").is_file(), "retirement:migration-receipt-missing")
    require(directory == directory.resolve(strict=True), "retirement:unsafe-journal-path")
    migration = load(directory / "journal.json")
    timing_context(repo=migration["repo"], source=str(bucket), archive=migration["archive"])
    require(inode(directory) == migration["directory_inode"], "retirement:journal-directory-changed")
    require(migration["source"]["identity"]["bucket_path"] == str(bucket), "retirement:wrong-bucket")
    git_only = migration["source"].get("capture_policy") == "git-only"
    require(migration["phase"] == ("archived" if git_only else "verified"), "retirement:migration-incomplete")
    descriptor = os.open(directory / "lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), "retirement:unsafe-lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if arguments.action == "retire-plan":
            return make_plan(directory, migration, descriptor)
        if arguments.action == "retire-status":
            return report(load(directory / "retirement.json"))
        if arguments.action == "retire-automatic":
            return automatic_retire(directory, migration, bucket, descriptor)
        return retire(directory, migration, arguments.confirm, descriptor)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("retire-plan", "retire", "retire-status", "retire-automatic"))
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--confirm", default="")
    arguments = parser.parse_args()
    try:
        print(json.dumps(execute(arguments), sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "retirement:evidence-unavailable"
        print(json.dumps({"state": "incomplete", "reason": reason, "retired": False,
                          **failure_details(error, "retirement")}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
