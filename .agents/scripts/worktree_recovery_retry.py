#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Scheduling hints for archive migration, never transaction/removal authority."""

from contextlib import contextmanager
import fcntl
import hashlib
import math
import os
from pathlib import Path
from secrets import randbelow
import shutil
import stat
import subprocess
import time

from worktree_lifetime_archive import require
from worktree_recovery_diagnostics import (
    FAILURE_DIAGNOSTIC_FIELDS as FAILURE_DIAGNOSTIC_FIELDS,
    failure_details as failure_details, restore_diagnostic as restore_diagnostic,
)
from worktree_recovery_migration_state import load, private_directory, publish
from worktree_recovery_retry_identity import already_completed, observe as observe

SCHEMA = "aidevops.worktree-recovery-retry/v1"
BACKOFF = (900, 3600, 21600, 86400)
SPACE_FLOOR = 64 * 1024 * 1024
REVISION_FILES = (
    "worktree_recovery_retry.py", "worktree_recovery_diagnostics.py", "worktree_recovery_retry_identity.py",
    "worktree_recovery_compact.py", "worktree_recovery_migrate.py",
    "worktree_recovery_retire.py", "worktree_recovery_retirement_transaction.py",
    "worktree_retirement_filesystem.py",
    "worktree_recovery_legacy_policy.py", "worktree_recovery_migration_state.py",
    "worktree_archive_restore.py", "worktree_archive_snapshot.py", "worktree-archive-helper.sh",
    "worktree-recovery-migrate-helper.sh", "worktree-recovery-retire-helper.sh",
    "worktree-recovery-lifecycle-helper.sh", "worktree_recovery_registry.py",
    "worktree_archive_administration.py", "worktree_archive_filesystem.py", "worktree_archive_git.py",
    "worktree_archive_index.py", "worktree_archive_state.py", "worktree_archive_history.py",
    "worktree_archive_objects.py", "worktree_archive_auto_merge.py", "worktree_archive_merge_capture.py",
    "worktree_archive_merge_restore.py", "worktree_archive_merge_objects.py",
)
TRANSIENT = {
    "compaction:deadline", "migration:insufficient-capacity", "migration:no-space",
    "retirement:process-active", "retirement:process-unavailable", "retirement:registry-active",
    "retirement:registry-busy",
    "retirement:worktree-reference-active", "retirement:claim-active",
}


def revision():
    scripts = Path(__file__).parent
    digest = hashlib.sha256()
    for name in REVISION_FILES:
        digest.update(name.encode() + b"\0" + (scripts / name).read_bytes())
    return digest.hexdigest()


def free_space(root):
    output = Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", str(Path.home() / ".aidevops/recovery/archives")))
    while not output.exists():
        output = output.parent
    return min(shutil.disk_usage(root).free, shutil.disk_usage(output).free)


def pending(identity, migration_revision):
    return {"schema": SCHEMA, "input_identity": identity, "migration_revision": migration_revision,
            "status": "pending", "last_attempt_at": None, "next_attempt_at": 0,
            "consecutive_failures": 0, "failure_code": None, "failure_stage": None}


def completed(record):
    record.update(status="completed", next_attempt_at=None, consecutive_failures=0,
                  failure_code=None, failure_stage=None)


def finish(record, code, stage, now, space=None):
    record.update(failure_code=code, failure_stage=stage)
    if code == "migration:lock-busy":
        delay = 600 + randbelow(301)
    elif code in TRANSIENT:
        record["consecutive_failures"] += 1
        delay = BACKOFF[min(record["consecutive_failures"] - 1, 3)]
        delay = min(86400, delay * (1 + randbelow(101) / 1000))
    else:
        record["consecutive_failures"] += 1
        record.update(status="blocked", next_attempt_at=None)
        return
    record.update(status="retry_wait", next_attempt_at=now + delay)
    if code in ("migration:no-space", "migration:insufficient-capacity"):
        record["space_required"] = max(SPACE_FLOOR, (space or 0) + SPACE_FLOOR)


@contextmanager
def schedule_lock(root, name):
    require(Path(name).name == name and name.startswith("aidevops-worktree-cleanup-"), "compaction:invalid-bucket")
    directory = root / ".compact-migrations" / name
    private_directory(directory.parent)
    private_directory(directory)
    descriptor = os.open(directory / "retry.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        value = os.fstat(descriptor)
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid()
                and not value.st_mode & 0o077, "migration:unsafe-lock")
        acquired = True
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            acquired = False
        yield directory if acquired else None
    finally:
        os.close(descriptor)


def validate_record(record):
    require(record.get("status") in ("pending", "running", "retry_wait", "blocked", "completed")
            and type(record.get("consecutive_failures")) is int
            and record["consecutive_failures"] >= 0, "migration:invalid-retry-state")
    for key in ("last_attempt_at", "next_attempt_at", "space_required"):
        value = record.get(key)
        valid_number = type(value) in (int, float) and math.isfinite(value) and value >= 0
        require(value is None or valid_number, "migration:invalid-retry-state")
    require(record["status"] not in ("running", "retry_wait") or record["next_attempt_at"] is not None,
            "migration:invalid-retry-state")


def current_record(path, identity, migration_revision):
    record = load(path, SCHEMA) if os.path.lexists(path) else pending(identity, migration_revision)
    validate_record(record)
    if (record["input_identity"], record["migration_revision"]) != (identity, migration_revision):
        record = pending(identity, migration_revision)
    return record


def hint(name, status, reason):
    return {"bucket": name, "retired": False, "status": status, "reason": reason}


def request_retry(root, name, migration_revision):
    """Reset only the schedule, under the same lock and input validation."""
    with schedule_lock(root, name) as directory:
        if directory is None:
            return hint(name, "running", "migration:lock-busy")
        identity, _ = observe(root, name, directory)
        path = directory / "retry.json"
        current_record(path, identity, migration_revision)
        publish(path, pending(identity, migration_revision))
        return hint(name, "pending", "compaction:retry-requested")


def invoke_compact(root, name, task):
    timeout, compact, started = task
    try:
        remaining = int(timeout - (time.monotonic() - started))
        if remaining <= 0:
            raise subprocess.TimeoutExpired("compact", timeout)
        return compact(root, name, remaining)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {"bucket": name, "retired": False, **failure_details(error, "compact")}


def attempt(root, directory, record, task):
    path = directory / "retry.json"
    # A running hint is NOT dead-worker evidence; producer/migration locks
    # still admit or refuse the child on restart.
    record.update(status="running", last_attempt_at=time.time(), next_attempt_at=time.time() + 900)
    publish(path, record)
    entry = invoke_compact(root, directory.name, task)
    record["input_identity"], _ = observe(root, directory.name, directory)
    if entry["retired"]:
        completed(record)
    else:
        finish(record, entry.get("failure_code", "compaction:unknown-failure"),
               entry.get("failure_stage", "compact"), time.time(), free_space(root))
    try:
        publish(path, record)
    except (OSError, ValueError):
        if not entry["retired"]:
            raise
        # An authoritative retired receipt must prevent a second retirement
        # even when publishing the scheduling hint fails.
        entry["schedule_error"] = "compaction:schedule-write-failed"
    entry["status"] = record["status"]
    return entry


def run_due(root, directory, record, task):
    space = free_space(root)
    if space >= record.get("space_required", SPACE_FLOOR):
        return attempt(root, directory, record, task)
    record.update(status="retry_wait", next_attempt_at=time.time() + 900,
                  failure_code="migration:no-space", failure_stage="space-check")
    publish(directory / "retry.json", record)
    return hint(directory.name, record["status"], record["failure_code"])


def reconcile(root, directory, record, ineligible):
    """Return a scheduling result, or None when a compaction attempt is due."""
    name = directory.name
    result = None
    if not ineligible and already_completed(directory, root / name):
        completed(record)
        result = hint(name, "completed", "compaction:already-completed")
    elif record["status"] in ("blocked", "completed") or (record["next_attempt_at"] or 0) > time.time():
        return hint(name, record["status"], "compaction:not-due")
    elif ineligible:
        finish(record, ineligible, "eligibility", time.time())
        result = hint(name, record["status"], record["failure_code"])
    if result is not None:
        publish(directory / "retry.json", record)
    return result


def scheduled(root, name, timeout, compact, migration_revision):
    started = time.monotonic()
    with schedule_lock(root, name) as directory:
        if directory is None:
            return hint(name, "running", "migration:lock-busy")
        identity, ineligible = observe(root, name, directory)
        record = current_record(directory / "retry.json", identity, migration_revision)
        result = reconcile(root, directory, record, ineligible)
        if result is None:
            result = run_due(root, directory, record, (timeout, compact, started))
        return result
