#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Migrate one validated legacy bucket without retiring or rewriting its source."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess  # nosec B404 -- fixed framework helper, argv only; see archive_command
import sys

from worktree_lifetime_archive import capacity, durable_archive, inode, require
from worktree_recovery_migration_scratch import finish_scratch, prepare_restore, verify_restore
from worktree_recovery_migration_state import (
    SCHEMA, allocated_bytes, load, manifest_digest, private_directory,
    publish, source_state,
)


SCRIPTS = Path(__file__).resolve().parent


def archive_command(lock, *arguments):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    # Keep the operation locked if this Python parent dies while Bash is still
    # capturing/restoring. A competing invocation must not start a second copy.
    bash = shutil.which("bash")
    require(bash is not None, "migration:bash-unavailable")
    result = subprocess.run(  # nosec B603 -- resolved Bash, framework helper, argv only
                            [str(Path(bash).absolute()), str(SCRIPTS / "worktree-archive-helper.sh"),
                             *map(str, arguments)], env=environment, pass_fds=(lock,),
                            capture_output=True, text=True, check=True, timeout=600)
    return result.stdout.strip()


def reserve(directory, output, identity, arguments):
    journal = directory / "journal.json"
    current = source_state(identity)
    if journal.exists() or journal.is_symlink():
        record = load(journal)
        require(record["source"] == current, "migration:source-drift")
        expected = {"directory_inode": inode(directory), "output": str(output),
                    "output_inode": inode(output), "repo": arguments.repo,
                    "base": arguments.base_branch}
        require({key: record[key] for key in expected} == expected,
                "migration:reservation-changed")
        return record
    require(not any(output.iterdir()), "migration:unrecorded-capture")
    required = capacity(Path(identity["archive_path"]), current["snapshot"])
    require(shutil.disk_usage(output).free >= required, "migration:insufficient-capacity")
    record = {"schema": SCHEMA, "phase": "reserved", "source": current,
              "directory_inode": inode(directory), "output": str(output),
              "output_inode": inode(output), "repo": arguments.repo,
              "base": arguments.base_branch, "source_retired": False,
              "reclaimed_bytes": 0, "bucket_bytes": allocated_bytes(Path(identity["bucket_path"]))}
    publish(journal, record)
    return record


def capture(directory, record, lock):
    output = Path(record["output"])
    worktree = record["source"]["identity"]["archive_path"]
    if not any(output.iterdir()):
        record["phase"] = "capturing"
        publish(directory / "journal.json", record)
        archive_command(lock, "archive", worktree, "--repo", record["repo"],
                        "--base-branch", record["base"], "--unattributed",
                        "--reason", "unattributed-worktree", "--self-contained",
                        "--include-ignored", "--preserve-git-admin", "--output-root", output)
    manifests = list(output.glob("*/*/*/manifest.json"))
    require(len(manifests) == 1, "migration:capture-incomplete; retained without another allocation")
    archive = manifests[0].parent
    require(archive == archive.resolve(strict=True), "migration:archive-path-changed")
    archive_command(lock, "verify", archive)
    archive_command(lock, "source-matches", archive, worktree)
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    require(manifest.get("self_contained") is True and manifest.get("include_ignored") is True
            and manifest.get("git_admin_policy") == "preserve-v1"
            and manifest.get("source_worktree") == worktree, "migration:wrong-archive-policy")
    pin = archive / ".aidevops-archive-pin"
    if not pin.exists() and not pin.is_symlink():
        descriptor = os.open(pin, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("Legacy migration: no retirement or expiry authority.\n")
    require(pin.is_file() and not pin.is_symlink(), "migration:unsafe-pin")
    durable_archive(archive)
    record.update(phase="captured", archive=str(archive), manifest_sha256=manifest_digest(archive))
    publish(directory / "journal.json", record)


def verify_archive(record, lock, check_source=True):
    archive = Path(record["archive"])
    output = Path(record["output"])
    require(archive == archive.resolve(strict=True) and archive.is_relative_to(output)
            and inode(output) == record["output_inode"], "migration:archive-path-changed")
    require(manifest_digest(archive) == record["manifest_sha256"], "migration:manifest-changed")
    archive_command(lock, "verify", archive)
    require(manifest_digest(archive) == record["manifest_sha256"], "migration:manifest-changed")
    require((archive / ".aidevops-archive-pin").is_file()
            and not (archive / ".aidevops-archive-pin").is_symlink(), "migration:pin-missing")
    if check_source:
        require(source_state(record["source"]["identity"]) == record["source"], "migration:source-drift")


def independent_restore(directory, record, lock):
    restored = prepare_restore(directory, record)
    if not restored.exists() and not restored.is_symlink():
        archive_command(lock, "restore", record["archive"], "--target", restored)
    verify_restore(restored, record)
    verify_archive(record, lock)
    record.update(phase="restore-verified", restore_inode=inode(restored),
                  archive_bytes=allocated_bytes(Path(record["archive"])))
    publish(directory / "journal.json", record)


def finish(directory, record, lock):
    verify_archive(record, lock)
    finish_scratch(directory, record)
    record["phase"] = "verified"
    publish(directory / "journal.json", record)


def migrate(directory, output, identity, arguments, lock):
    record = reserve(directory, output, identity, arguments)
    if record["phase"] in ("reserved", "capturing"):
        capture(directory, record, lock)
    if record["phase"] == "captured":
        verify_archive(record, lock)
        independent_restore(directory, record, lock)
    if record["phase"] in ("restore-verified", "cleanup-pending"):
        finish(directory, record, lock)
    require(record["phase"] == "verified", "migration:incomplete-phase")
    verify_archive(record, lock)
    return {"state": "verified", "receipt": str(directory / "journal.json"),
            "archive": record["archive"], "bucket_bytes": record["bucket_bytes"],
            "archive_bytes": record["archive_bytes"], "source_retired": False, "reclaimed_bytes": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base-branch", required=True)
    arguments = parser.parse_args()
    identity = json.load(sys.stdin)
    bucket = Path(identity["bucket_path"])
    private_directory(bucket.parent / ".compact-migrations")
    directory = bucket.parent / ".compact-migrations" / bucket.name
    private_directory(directory)
    root = Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", str(Path.home() / ".aidevops/recovery/archives")))
    identifier = hashlib.sha256(os.fsencode(bucket)).hexdigest()
    output = root / ".legacy-migrations" / identifier
    require(not output.is_relative_to(bucket), "migration:output-inside-source")
    private_directory(output)
    lock = os.open(directory / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(lock).st_mode), "migration:unsafe-lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(json.dumps(migrate(directory, output, identity, arguments, lock), sort_keys=True))
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "migration:evidence-unavailable"
        print(json.dumps({"state": "incomplete", "reason": reason, "source_retired": False}))
        sys.exit(1)
