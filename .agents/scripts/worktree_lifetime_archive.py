#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Journal idle archive verification in the existing managed-lifetime registry.

Interrupted construction is retained, not retried into another copy. A completed
restore receipt permits resumable scratch cleanup and source removal checks.
This command never removes the source worktree; the existing removal guard does.
"""

import argparse
from contextlib import closing, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import time
import uuid

from worktree_archive_snapshot import git, snapshot


SCRIPTS = Path(__file__).resolve().parent


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def managed_module():
    specification = importlib.util.spec_from_file_location("archive_managed_lifetime", SCRIPTS / "worktree-managed-lifetime.py")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


@contextmanager
def transaction():
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    database = Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")
    require(database.is_file() and not database.is_symlink(), "registry unavailable")
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=rw", uri=True,
                                isolation_level=None, timeout=10)) as connection:
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("BEGIN IMMEDIATE")
        try:
            yield connection
            connection.execute("COMMIT")
        except BaseException:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise


def helper(*arguments):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    result = subprocess.run(["bash", str(SCRIPTS / "worktree-archive-helper.sh"), *arguments],
                            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, check=True, timeout=180)
    return result.stdout.strip()


def inode(path):
    value = path.lstat()
    return f"{value.st_dev}:{value.st_ino}"


def operation(record):
    value = record.get("archive_operation")
    require(isinstance(value, dict) and value.get("schema") == 1, "archive operation unavailable")
    require(value.get("generation") == record.get("generation") and value.get("identity") == record["identity"],
            "archive operation generation changed")
    return value


def operation_directory(value):
    directory = Path(value["directory"])
    require(directory.is_absolute() and directory.name == value["id"], "invalid operation directory")
    require(directory == directory.resolve(strict=True) and inode(directory) == value["directory_inode"],
            "operation directory identity changed")
    return directory


def require_verified(record, source=True):
    """Gate used by native removal as well as retries; absence preserves old API."""
    if "archive_operation" not in record:
        return
    value = operation(record)
    require(value["phase"] in ("restore-verified", "verified", "removed"), "archive restore not verified")
    directory = operation_directory(value)
    archive = Path(value["archive"])
    require(archive == archive.resolve(strict=True) and archive.is_relative_to(directory / "archives"),
            "archive location changed")
    manifest = archive / "manifest.json"
    require(hashlib.sha256(manifest.read_bytes()).hexdigest() == value["manifest_sha256"], "archive manifest changed")
    helper("verify", str(archive))
    require(hashlib.sha256(manifest.read_bytes()).hexdigest() == value["manifest_sha256"], "archive changed during verification")
    if source:
        require(snapshot(record["identity"]["path"]) == value["snapshot"], "source changed since verified restoration")


def update(managed, path, identifier, changes):
    with transaction() as connection:
        record = managed.load(connection, str(path))
        value = operation(record)
        require(value["id"] == identifier, "archive operation replaced")
        value.update(changes)
        managed.save(connection, record)
    return record


def capacity(path, baseline):
    counts = dict(line.split(b": ", 1) for line in git(path, "count-objects", "-v").splitlines())
    objects = (int(counts[b"size"]) + int(counts[b"size-pack"])) * 1024
    head_entries = git(path, "ls-tree", "-r", "-l", "-z", "HEAD").split(b"\0")
    head_bytes = sum(int(entry.split(b"\t", 1)[0].split()[3]) for entry in head_entries if entry)
    index_entries = git(path, "ls-files", "--stage", "-z").split(b"\0")
    object_ids = [entry.split(b"\t", 1)[0].split()[1] for entry in index_entries if entry]
    index_bytes = 0
    if object_ids:
        sizes = git(path, "cat-file", "--batch-check=%(objectsize)", data=b"\n".join(object_ids) + b"\n")
        index_bytes = sum(int(size) for size in sizes.splitlines())
    # Include expanded HEAD/index and dirty/untracked payloads, not just compressed
    # Git objects. Reserve conservative patch/restore overhead and a 1 GiB floor.
    # Concurrent allocations can still cause ENOSPC, which must fail closed.
    return 1024 ** 3 + 3 * (objects + head_bytes + index_bytes + baseline["bytes"])


def initialize(managed, path, root, required_capacity, idle_seconds=86400):
    require(type(idle_seconds) is int and idle_seconds >= managed.idle_policy.IDLE_SECONDS,
            "idle window must be at least 86400 seconds")
    with transaction() as connection:
        record = managed.load(connection, str(path))
        managed.verify_identity(record, path)
        managed.idle_policy.owner_clear(connection, str(path))
        if "archive_operation" in record:
            authorized_window = operation(record).get("idle_window_seconds", 86400)
            require(type(authorized_window) is int and idle_seconds <= authorized_window,
                    "stricter idle window requires a new preservation decision; existing recovery retained")
            return record, False
        require(shutil.disk_usage(root).free >= required_capacity,
                "insufficient archive capacity; no cleanup authorization issued")
        managed.idle_policy.require_elapsed(record, managed.boot_id(), idle_seconds)
        managed.idle_quiescence(record)
        identifier = uuid.uuid4().hex
        record["archive_operation"] = {
            "schema": 1, "id": identifier, "generation": record["generation"],
            "identity": record["identity"], "authorized_idle": record["idle"],
            "idle_window_seconds": idle_seconds,
            "directory": str(root / identifier), "phase": "reserved",
            "owner_pid": os.getpid(), "owner_boot": managed.boot_id(), "started_at": time.time(),
        }
        managed.save(connection, record)
    return record, True


def owner_active(managed, value):
    if value["owner_boot"] != managed.boot_id():
        return False
    try:
        os.kill(value["owner_pid"], 0)
    except ProcessLookupError:
        return False
    return True


def finish_scratch(managed, path, record):
    value = operation(record)
    directory = operation_directory(value)
    require_verified(record)
    with transaction() as connection:
        current = managed.load(connection, str(path))
        live = operation(current)
        require(live["id"] == value["id"] and live["phase"] == "restore-verified", "archive phase changed")
        require(live["owner_pid"] == os.getpid() or not owner_active(managed, live), "archive owner remains active")
        live.update(owner_pid=os.getpid(), owner_boot=managed.boot_id())
        managed.save(connection, current)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            observed = os.stat("restore", dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            observed = None
        if observed is not None:
            require(f"{observed.st_dev}:{observed.st_ino}" == value["restore_inode"], "restore scratch identity changed")
            require(shutil.rmtree.avoids_symlink_attacks, "safe scratch cleanup unavailable")
            shutil.rmtree("restore", dir_fd=descriptor)
    finally:
        os.close(descriptor)
    return update(managed, path, value["id"], {"phase": "verified", "verified_at": time.time()})


def durable_archive(archive):
    # SQLite durability does not flush separately written recovery artifacts.
    # Require filesystem fsync support before publishing removal authorization.
    for artifact in archive.iterdir():
        descriptor = os.open(artifact, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            require(stat.S_ISREG(os.fstat(descriptor).st_mode), "unsafe recovery artifact")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    for directory in (archive, *archive.parents):
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def record_failure(managed, path, identifier, error):
    with transaction() as connection:
        record = managed.load(connection, str(path))
        value = operation(record)
        require(value["id"] == identifier, "archive operation replaced")
        if value["phase"] not in ("restore-verified", "verified"):
            value["phase"] = "blocked"
        value.update(failure=type(error).__name__, failed_at=time.time())
        managed.save(connection, record)


def construct(managed, path, record, arguments):
    value = operation(record)
    directory = Path(value["directory"])
    directory.mkdir(mode=0o700)
    baseline = snapshot(path)
    update(managed, path, value["id"], {"phase": "building", "directory_inode": inode(directory), "snapshot": baseline})
    archive_args = ["archive", str(path), "--repo", arguments.repo, "--base-branch", arguments.base,
                    "--self-contained", "--output-root", str(directory / "archives")]
    if arguments.issue:
        archive_args.extend(["--issue", arguments.issue, "--reason", "failed-worker"])
    else:
        archive_args.extend(["--unattributed", "--reason", "unattributed-worktree"])
    archive = Path(helper(*archive_args))
    helper("verify", str(archive))
    manifest_digest = hashlib.sha256((archive / "manifest.json").read_bytes()).hexdigest()
    target = directory / "restore"
    helper("restore", str(archive), "--target", str(target))
    require(snapshot(target) == baseline and snapshot(path) == baseline, "restoration or source comparison failed")
    durable_archive(archive)
    helper("verify", str(archive))
    require(hashlib.sha256((archive / "manifest.json").read_bytes()).hexdigest() == manifest_digest,
            "archive changed during independent restoration")
    record = update(managed, path, value["id"], {
        "phase": "restore-verified", "archive": str(archive), "restore_inode": inode(target),
        "manifest_sha256": manifest_digest,
        "restored_at": time.time(),
    })
    return finish_scratch(managed, path, record)


def prepare(managed, path, arguments):
    root = Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT") or Path.home() / ".aidevops/recovery/archives") / ".lifecycle"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root = root.resolve(strict=True)
    baseline = snapshot(path)  # Unsupported contents must not seal the source.
    required_capacity = capacity(path, baseline)
    record, fresh = initialize(managed, path, root, required_capacity, getattr(arguments, "idle_seconds", 86400))
    value = operation(record)
    if fresh:
        try:
            record = construct(managed, path, record, arguments)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            record_failure(managed, path, value["id"], error)
            raise
    elif value["phase"] == "restore-verified":
        record = finish_scratch(managed, path, record)
    else:
        require(value["phase"] == "verified", "incomplete archive attempt retained; no duplicate allocation")
    require_verified(record)
    return operation(record)["archive"]


def finish_removal(managed, path, record):
    require(operation(record)["phase"] in ("verified", "removed"), "removal receipt requires verified archive")
    common = Path(record["identity"]["common"])
    require(path.parent.is_dir() and common.is_dir() and not common.is_symlink(),
            "source parent or common repository unavailable")
    for candidate in (path, Path(record["identity"]["admin"])):
        try:
            candidate.lstat()
        except FileNotFoundError:
            continue
        raise ValueError("source or Git registration remains")
    require_verified(record, source=False)
    if operation(record)["phase"] != "removed":
        update(managed, path, operation(record)["id"], {
            "phase": "removed", "removed_at": time.time(),
            "removal_evidence": "source-and-registration-absent",
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "ready", "removed", "status"))
    parser.add_argument("path")
    parser.add_argument("--repo")
    parser.add_argument("--issue")
    parser.add_argument("--base")
    parser.add_argument("--idle-seconds", type=int, default=86400)
    arguments = parser.parse_args()
    managed = managed_module()
    path = Path(arguments.path)
    require(path.is_absolute() and str(path) == os.path.realpath(path), "canonical absolute path required")
    if arguments.operation == "prepare":
        require(bool(arguments.repo and arguments.base), "repository and base required")
        print(prepare(managed, path, arguments))
        return 0
    with transaction() as connection:
        record = managed.load(connection, str(path))
        if arguments.operation == "ready":
            managed.idle_policy.owner_clear(connection, str(path))
    if arguments.operation == "status":
        print(json.dumps(record.get("archive_operation"), sort_keys=True))
        return 0
    if arguments.operation == "ready":
        managed.verify_identity(record, path)
        managed.proof(record, managed.inode(path))
        require(operation(record)["phase"] == "verified", "archive is not removal-ready")
        require_verified(record)
        return 0
    finish_removal(managed, path, record)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "archive evidence unavailable"
        print(f"lifetime-archive: {reason}", file=sys.stderr)
        sys.exit(1)
