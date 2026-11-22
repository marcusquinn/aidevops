#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Explicit worker-cohort maintenance observations, not historical completion.

The operator selects a worker-only source using independent native launch logs.
This policy is not applicable to arbitrary worktrees or ordinary background
cleanup. A missing systemd unit and a dead parent are never completion receipts.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
from contextlib import closing

import worktree_lifetime_owner as owner
import worktree_maintenance_boundary as boundary
import worktree_process_snapshot as census

require = boundary.require
POLICY = "aidevops-worker-cohort/v1"
LOG_ROOT = Path.home() / ".aidevops/logs"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def validate_selection(selection):
    reason = "maintenance:unsupported-worker-policy"
    require(isinstance(selection, dict), reason)
    require(selection.get("policy") == POLICY, reason)
    flags = ("discard_ignored", "archive_local_commits", "archive_blocked")
    require(all(type(selection.get(flag)) is bool for flag in flags), reason)


def prefix(path, runtime=False):
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.realpath(path),
            "maintenance:noncanonical-evidence")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o022, "maintenance:untrusted-evidence")
        content = os.read(descriptor, 65536)
        require(runtime or info.st_size <= 65536, "maintenance:evidence-too-large")
    finally:
        os.close(descriptor)
    if runtime:
        marker = b"[lifecycle] pre_runtime_launch "
        require(marker in content, "maintenance:missing-native-runtime-prefix")
        # Model output is not evidence, including arbitrary bytes or a partial
        # UTF-8 character at the read boundary after the native launch prefix.
        content = content.split(marker, 1)[0]
    return ANSI.sub("", content.decode("utf-8", errors="strict"))


def event(text, name):
    matches = [line for line in text.splitlines() if "[lifecycle] " + name + " " in line]
    require(len(matches) == 1, "maintenance:ambiguous-native-event:" + name)
    return dict(re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", matches[0]))


def evidence(path, selection):
    launch = Path(selection["launch_log"])
    runtime = Path(selection["runtime_log"])
    require(launch.is_relative_to(LOG_ROOT), "maintenance:controller-log-outside-native-log-root")
    controller = prefix(launch)
    expected = "[INFO] Detaching worker (log: " + str(runtime) + ")"
    require(expected in controller.splitlines(), "maintenance:runtime-log-not-bound")
    admitted = event(controller, "worker_detached")
    require(admitted.get("isolation") == "systemd_scope", "maintenance:unconfirmed-worker-launch")
    session, pid, attempt = (admitted.get(key, "") for key in ("session", "pid", "attempt_id"))
    require(re.fullmatch(r"[A-Za-z0-9_.-]+", session) is not None
            and re.fullmatch(r"[1-9][0-9]*", pid) is not None
            and re.fullmatch(r"attempt:[0-9a-f-]{36}", attempt) is not None,
            "maintenance:invalid-worker-identity")
    unit = admitted.get("unit", "")
    require(re.fullmatch(r"aidevops-worker-" + re.escape(session) + r"-[0-9]+-[0-9]+\.scope", unit)
            is not None, "maintenance:invalid-worker-scope")
    native = prefix(runtime, runtime=True)
    prepared = event(native, "post_worker_prepare")
    require(all(prepared.get(key) == admitted.get(key) for key in ("session", "pid", "attempt_id"))
            and prepared.get("work_dir") == str(path), "maintenance:worker-source-not-bound")
    return {"policy": POLICY, "session": session, "unit": unit, "attempt": attempt,
            "launch_sha256": hashlib.sha256(controller.encode()).hexdigest(),
            "runtime_prefix_sha256": hashlib.sha256(native.encode()).hexdigest()}


def require_unused(path):
    """Require full CWD visibility as well as absence of recognized workers.

    A detached descendant need not retain launcher arguments. Native launch
    evidence and an empty launcher match therefore cannot clear unknown CWDs.
    """
    boundary.require_unused(path)
    source = str(path)
    snapshot = census.capture()
    require(snapshot.get("status") == "available" and not any((
        snapshot["uncertain_pids"], snapshot["membership_unavailable"],
        snapshot["runtime_inspection_unavailable"])), "maintenance:worker-census-unavailable")
    require(not any(process.get("worker_worktree") is not None
                    and Path(process["worker_worktree"]).is_relative_to(source)
                    for process in snapshot["processes"].values()), "maintenance:active-worker")
    return snapshot


def owner_clear(claim, snapshot):
    if claim is None:
        return
    pid, _session, _task, start = claim
    require(type(pid) is int and pid > 0, "maintenance:invalid-owner")
    process = snapshot["processes"].get(pid)
    if process is None or process["state"] in ("Z", "X"):
        return
    require(isinstance(start, str) and start.isdecimal(), "maintenance:owner-generation-unavailable")
    if process["start"] != start:
        return
    raise ValueError("maintenance:live-owner")


def legacy_observation(item):
    if not isinstance(item, dict):
        return False
    return ((item.get("kind"), item.get("evidence")) == (owner.KIND, "observed")
            and not any(item.get(field) for field in
                        ("completion_evidence", "unit", "invocation", "quiescence")))


def legacy(database, path):
    with closing(sqlite3.connect(database, uri=True, timeout=3)) as connection:
        row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path = ?",
                                 (str(path),)).fetchone()
        require(row is not None, "maintenance:not-enrolled")
        record = json.loads(row[0])
        claim = connection.execute("SELECT owner_pid FROM worktree_owners WHERE worktree_path = ?",
                                   (str(path),)).fetchone()
    require(record.get("manager") == owner.MANAGER and record.get("state") == "running",
            "maintenance:not-legacy-running")
    launches = record.get("launches")
    require(isinstance(launches, list) and launches and all(legacy_observation(item) for item in launches),
        "maintenance:not-legacy-admission")
    require(not record.get("archive_operation"), "maintenance:existing-archive-operation")
    require(record.get("identity") == owner.identity(path), "maintenance:identity-changed")
    if claim:
        require(type(claim[0]) is int and claim[0] > 0, "maintenance:invalid-owner")
        try:
            os.kill(claim[0], 0)
        except ProcessLookupError:
            pass
        else:
            raise ValueError("maintenance:live-owner")
    return record


def legacy_binding(database, path, snapshot):
    """Bind absent/observation-only history without replacing any lifetime."""
    with closing(sqlite3.connect(database, uri=True, timeout=3)) as connection:
        row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path=?",
                                 (str(path),)).fetchone()
        claim = connection.execute("""SELECT owner_pid, owner_session, task_id, owner_process_start
            FROM worktree_owners WHERE worktree_path=?""", (str(path),)).fetchone()
    owner_clear(claim, snapshot)
    identity = owner.identity(path)
    record = json.loads(row[0]) if row is not None else None
    if record is not None:
        require(isinstance(record, dict) and record.get("manager") == owner.MANAGER
                and record.get("state") == "running", "maintenance:not-observation-only-worker")
        launches = record.get("launches")
        require(isinstance(launches, list) and bool(launches) and all(map(legacy_observation, launches)),
                "maintenance:not-observation-only-worker")
        owner.require_admission_observed(record)
        require(record.get("identity") == identity and not record.get("archive_operation"),
                "maintenance:legacy-worker-identity-or-operation-changed")
    record_digest = None if record is None else hashlib.sha256(
        json.dumps(record, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"identity": identity, "lifecycle_record_sha256": record_digest}
