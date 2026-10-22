#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Scheduling hints for archive migration, never transaction/removal authority."""

import errno
import fcntl
import hashlib
from itertools import islice
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import stat
import subprocess
import time

from worktree_lifetime_archive import inode, require
from worktree_recovery_migration_state import load, opaque_file, private_directory, publish

SCHEMA = "aidevops.worktree-recovery-retry/v1"
BACKOFF = (900, 3600, 21600, 86400)
SPACE_FLOOR = 64 * 1024 * 1024
REVISION_FILES = (
    "worktree_recovery_retry.py", "worktree_recovery_compact.py", "worktree_recovery_migrate.py",
    "worktree_recovery_retire.py", "worktree_recovery_retirement_transaction.py",
    "worktree_recovery_legacy_policy.py", "worktree_recovery_migration_state.py",
    "worktree_archive_restore.py", "worktree_archive_snapshot.py", "worktree-archive-helper.sh",
    "worktree-recovery-migrate-helper.sh", "worktree-recovery-retire-helper.sh",
    "worktree-recovery-lifecycle-helper.sh",
    "worktree_archive_administration.py", "worktree_archive_filesystem.py", "worktree_archive_git.py",
    "worktree_archive_index.py", "worktree_archive_state.py",
    "worktree_archive_objects.py", "worktree_archive_auto_merge.py", "worktree_archive_merge_capture.py",
    "worktree_archive_merge_restore.py", "worktree_archive_merge_objects.py",
)
TRANSIENT = {
    "compaction:deadline", "migration:insufficient-capacity", "migration:no-space",
    "retirement:process-active", "retirement:process-unavailable", "retirement:registry-active",
    "retirement:worktree-reference-active", "retirement:claim-active",
}
DIAGNOSTIC_PREFIX = "archive-restore-diagnostic:"
DIAGNOSTIC_HINTS = {
    "no-space": "No space left on device",
    "reference-lock": "cannot lock ref",
    "file-exists": "File exists",
    "permission-denied": "Permission denied",
    "database-locked": "database is locked",
    "ownership-transaction": "Worktree ownership transaction unavailable",
    "invalid-reference": "invalid reference",
    "missing-object": "not a valid object",
}
GIT_OPERATIONS = {"fetch", "bundle", "worktree", "cat-file", "rev-parse", "update-ref"}
FAILURE_DIAGNOSTIC_FIELDS = (
    "failure_exit_status", "failure_child_exit_status", "failure_child_stderr_sha256",
    "failure_git_operation", "failure_hints",
)


def restore_diagnostic(error):
    """Summarize captured child errors without emitting paths, argv or raw stderr."""
    data = getattr(error, "stderr", None) or b""
    if isinstance(data, str):
        data = data.encode("utf-8", errors="replace")
    text = data.decode("utf-8", errors="replace")
    values = ["stderr-sha256:" + hashlib.sha256(data).hexdigest()]
    if isinstance(error, subprocess.CalledProcessError):
        values.append("exit-status:" + str(error.returncode))
        command = error.cmd
        if isinstance(command, (list, tuple)) and command and Path(str(command[0])).name == "git":
            operation = next((arg for arg in command[1:] if arg in GIT_OPERATIONS), None)
            if operation:
                values.append("git-operation:" + operation)
    values.extend("hint:" + hint for hint, phrase in DIAGNOSTIC_HINTS.items() if phrase in text)
    return "\n".join(DIAGNOSTIC_PREFIX + value for value in values)


def revision():
    scripts = Path(__file__).parent
    digest = hashlib.sha256()
    for name in REVISION_FILES:
        digest.update(name.encode() + b"\0" + (scripts / name).read_bytes())
    return digest.hexdigest()


def failure_details(error, stage):
    """Emit bounded codes from actual errno/helper diagnostics; unknowns block."""
    code = "compaction:unknown-failure"
    details = {}
    if isinstance(error, OSError) and error.errno == errno.ENOSPC:
        code = "migration:no-space"
    elif isinstance(error, BlockingIOError) and error.errno in (errno.EAGAIN, errno.EACCES):
        code = "migration:lock-busy"
    elif isinstance(error, subprocess.TimeoutExpired):
        code = "compaction:deadline"
    elif isinstance(error, ValueError):
        candidate = str(error).split(";", 1)[0]
        # Framework ValueErrors carry fixed codes. Never promote raw Git paths
        # or unfamiliar diagnostics into machine-readable failure authority.
        if candidate.startswith(("migration:", "retirement:", "restore-proof:", "git_admin:")):
            if len(candidate) <= 128 and all(char.isalnum() or char in ":-_" for char in candidate):
                code = candidate
    elif isinstance(error, subprocess.CalledProcessError):
        diagnostic = error.stderr or ""
        if isinstance(diagnostic, bytes):
            diagnostic = diagnostic.decode(errors="replace")
        details["failure_exit_status"] = error.returncode
        # Accept only fixed tokens and a digest from the restore boundary. The
        # child's stderr/traceback and command can contain private paths or data.
        hints = [hint for hint in DIAGNOSTIC_HINTS
                 if DIAGNOSTIC_PREFIX + "hint:" + hint in diagnostic.splitlines()]
        if hints:
            details["failure_hints"] = hints
        patterns = {"failure_child_exit_status": r"exit-status:(-?[0-9]{1,9})",
                    "failure_child_stderr_sha256": r"stderr-sha256:([0-9a-f]{64})",
                    "failure_git_operation": r"git-operation:(" + "|".join(sorted(GIT_OPERATIONS)) + r")"}
        for key, pattern in patterns.items():
            match = re.search("^" + DIAGNOSTIC_PREFIX + pattern + "$", diagnostic, re.MULTILINE)
            if match:
                details[key] = int(match[1]) if key == "failure_child_exit_status" else match[1]
        if "No space left on device" in diagnostic or "no-space" in hints:
            code = "migration:no-space"
        elif "artifact integrity mismatch:" in diagnostic:
            code = "archive:artifact-integrity-mismatch"
        elif "unsupported untracked path type" in diagnostic:
            code = "archive:unsupported-untracked-path"
    return {"failure_code": code, "failure_stage": getattr(error, "recovery_stage", stage), **details}


def stamp(path):
    if not os.path.lexists(path):
        return None
    value = path.lstat()
    require(not stat.S_ISLNK(value.st_mode), "migration:source-path-changed")
    return [value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns]


def observe(root, name, directory):
    """Bounded metadata only: no Git, recursive sizes, process scans or payload IO."""
    bucket = root / name
    identity = {"root_inode": inode(root), "bucket_inode": inode(bucket) if bucket.is_dir() else None}
    code = None
    try:
        require(not bucket.is_symlink(), "migration:source-path-changed")
        journal = directory / "journal.json"
        if os.path.lexists(journal):
            saved = load(journal)
            source = saved["source"]
            require(saved["directory_inode"] == inode(directory)
                    and source["identity"]["bucket_path"] == str(bucket), "migration:reservation-changed")
            require(source.get("capture_policy") == "git-only"
                    and source["identity"]["source_removal_outcome"] == "removed",
                    "migration:incomplete-archived-copy")
            require(identity["bucket_inode"] in (None, source["bucket_inode"]),
                    "migration:source-identity-conflict")
            identity["bucket_inode"] = source["bucket_inode"]
            identity["source"] = source
            worktree = Path(source["identity"]["archive_path"])
            common = Path(source["identity"]["common_path"])
            archive = Path(saved["archive"]) if "archive" in saved else None
            if archive:
                require(archive == archive.resolve(), "migration:archive-path-changed")
                # Artifact stat changes wake a blocked attempt; verification still
                # hashes all bytes. Never copy the transaction phase into retry.json.
                entries = list(islice(archive.iterdir(), 65))
                require(len(entries) <= 64, "migration:oversized-artifact-inventory")
                identity["artifacts"] = {p.name: stamp(p) for p in entries}
        else:
            metadata = bucket / ".aidevops-worktree-recovery"
            require(metadata.is_dir() and not metadata.is_symlink(), "migration:incomplete-archived-copy")
            fields = ("format", "archive-complete", "source-removal-outcome", "source-real", "source-inode",
                      "head", "branch", "common-real", "producer", "producer-context", "created-at",
                      "storage-owner", "storage-class", "storage-policy", "storage-root")
            identity["metadata"] = {field: opaque_file(metadata / field) for field in fields}
            values = {key: bytes.fromhex(value["hex"]).decode().rstrip("\n")
                      for key, value in identity["metadata"].items()}
            require(values["format"] == values["archive-complete"] == "aidevops-worktree-recovery-v2"
                    and values["source-removal-outcome"] == "removed"
                    and values["storage-owner"] == "framework" and values["storage-class"] == "recovery"
                    and values["storage-policy"] == "manual-review" and values["storage-root"] == str(root),
                    "migration:incomplete-archived-copy")
            entries = list(islice(bucket.iterdir(), 3))
            worktrees = [entry for entry in entries if entry != metadata]
            require(len(entries) == 2 and len(worktrees) == 1 and worktrees[0].is_dir(),
                    "migration:incomplete-archived-copy")
            worktree = worktrees[0]
            common = Path(values["common-real"])
        # Detect ordinary HEAD/index/entry replacement cheaply; unchanged nested
        # working-file edits may require explicit retry, never a recursive scan.
        metadata = bucket / ".aidevops-worktree-recovery"
        require(not metadata.is_symlink() and not (metadata / "admin").is_symlink(),
                "migration:source-path-changed")
        require(worktree.parent == bucket and common.is_absolute(), "migration:source-path-changed")
        identity["worktree"] = stamp(worktree)
        identity["base_inode"] = inode(common) if common.is_dir() else None
        identity["admin"] = {key: stamp(metadata / "admin" / key) for key in ("HEAD", "index")}
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        code = failure_details(error, "eligibility")["failure_code"]
        identity["observation_error"] = code
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return digest, code


def free_space(root):
    output = Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", str(Path.home() / ".aidevops/recovery/archives")))
    while not output.exists():
        output = output.parent
    return min(shutil.disk_usage(root).free, shutil.disk_usage(output).free)


def pending(identity, migration_revision):
    return {"schema": SCHEMA, "input_identity": identity, "migration_revision": migration_revision,
            "status": "pending", "last_attempt_at": None, "next_attempt_at": 0,
            "consecutive_failures": 0, "failure_code": None, "failure_stage": None}


def finish(record, code, stage, now, space=None):
    record.update(failure_code=code, failure_stage=stage)
    if code == "migration:lock-busy":
        delay = random.uniform(600, 900)
    elif code in TRANSIENT:
        record["consecutive_failures"] += 1
        delay = BACKOFF[min(record["consecutive_failures"] - 1, 3)]
        delay = min(86400, delay * random.uniform(1, 1.1))
    else:
        record["consecutive_failures"] += 1
        record.update(status="blocked", next_attempt_at=None)
        return
    record.update(status="retry_wait", next_attempt_at=now + delay)
    if code in ("migration:no-space", "migration:insufficient-capacity"):
        record["space_required"] = max(SPACE_FLOOR, (space or 0) + SPACE_FLOOR)


def already_completed(directory, bucket):
    path = directory / "retirement.json"
    if not os.path.lexists(path):
        return False
    retired = load(path)
    if retired.get("phase") != "retired":
        return False
    migration = load(directory / "journal.json")
    require(retired.get("kind") == "retirement" and retired.get("authority") == "verified-git-changes/v1"
            and retired["bucket"] == str(bucket) and not os.path.lexists(bucket)
            and retired["bucket_inode"] == migration["source"]["bucket_inode"]
            and retired["archive"] == migration["archive"]
            and migration["directory_inode"] == inode(directory), "migration:completion-identity-conflict")
    return True


def scheduled(root, name, timeout, compact, migration_revision, retry_only=False):
    started = time.monotonic()
    require(Path(name).name == name and name.startswith("aidevops-worktree-cleanup-"), "compaction:invalid-bucket")
    directory = root / ".compact-migrations" / name
    private_directory(directory.parent)
    private_directory(directory)
    descriptor = os.open(directory / "retry.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        value = os.fstat(descriptor)
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid()
                and not value.st_mode & 0o077, "migration:unsafe-lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"bucket": name, "retired": False, "reason": "migration:lock-busy", "status": "running"}
        path = directory / "retry.json"
        now = time.time()
        identity, ineligible = observe(root, name, directory)
        record = load(path, SCHEMA) if os.path.lexists(path) else pending(identity, migration_revision)
        require(record.get("status") in ("pending", "running", "retry_wait", "blocked", "completed")
                and type(record.get("consecutive_failures")) is int
                and record["consecutive_failures"] >= 0, "migration:invalid-retry-state")
        for key in ("last_attempt_at", "next_attempt_at", "space_required"):
            value = record.get(key)
            require(value is None or (type(value) in (int, float) and math.isfinite(value) and value >= 0),
                    "migration:invalid-retry-state")
        require(record["status"] not in ("running", "retry_wait") or record["next_attempt_at"] is not None,
                "migration:invalid-retry-state")
        if (record["input_identity"], record["migration_revision"]) != (identity, migration_revision) or retry_only:
            record = pending(identity, migration_revision)
        if retry_only:
            publish(path, record)
            return {"bucket": name, "retired": False, "status": "pending", "reason": "compaction:retry-requested"}
        if not ineligible and already_completed(directory, root / name):
            record.update(status="completed", next_attempt_at=None, consecutive_failures=0,
                          failure_code=None, failure_stage=None)
            publish(path, record)
            return {"bucket": name, "retired": False, "status": "completed", "reason": "compaction:already-completed"}
        if record["status"] in ("blocked", "completed") or (record["next_attempt_at"] or 0) > now:
            return {"bucket": name, "retired": False, "status": record["status"], "reason": "compaction:not-due"}
        if ineligible:
            finish(record, ineligible, "eligibility", now)
        else:
            space = free_space(root)
            if space < record.get("space_required", SPACE_FLOOR):
                record.update(status="retry_wait", next_attempt_at=now + 900,
                              failure_code="migration:no-space", failure_stage="space-check")
            else:
                # A running record is NOT dead-worker evidence. On restart the
                # ordinary producer/migration locks still admit or refuse the child.
                record.update(status="running", last_attempt_at=now, next_attempt_at=now + 900)
                publish(path, record)
                try:
                    remaining = int(timeout - (time.monotonic() - started))
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired("compact", timeout)
                    entry = compact(root, name, remaining)
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    entry = {"bucket": name, "retired": False, **failure_details(error, "compact")}
                record["input_identity"], _ = observe(root, name, directory)
                if entry["retired"]:
                    record.update(status="completed", next_attempt_at=None, consecutive_failures=0,
                                  failure_code=None, failure_stage=None)
                else:
                    finish(record, entry.get("failure_code", "compaction:unknown-failure"),
                           entry.get("failure_stage", "compact"), time.time(), free_space(root))
                try:
                    publish(path, record)
                except (OSError, ValueError):
                    if not entry["retired"]:
                        raise
                    # The child has an authoritative retired receipt. Failure to
                    # publish this hint must not permit a second retirement/pass.
                    entry["schedule_error"] = "compaction:schedule-write-failed"
                entry["status"] = record["status"]
                return entry
        publish(path, record)
        return {"bucket": name, "retired": False, "status": record["status"], "reason": record["failure_code"]}
    finally:
        os.close(descriptor)
