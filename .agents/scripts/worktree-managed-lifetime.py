#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Rootless, cooperative Pulse worktree lifetime evidence in the existing registry.

Only newly created dispatcher worktrees enroll. No inference from branch names,
missing owner rows, dead wrapper PIDs, or missing systemd units grants authority.
Workers must not hand work to an untracked service or external process.
"""

from __future__ import annotations

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import uuid

import worktree_lifetime_idle as idle_policy
import worktree_lifetime_proof as lifetime_proof


TABLE = "worktree_managed_lifetimes"


class NotEnrolled(ValueError):
    """Definitive absence, distinct from unavailable or corrupt evidence."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def command(argv: list[str]) -> str:
    # Internal git/systemctl argv only; paths and unit names are validated, no shell.
    return subprocess.check_output(argv, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()  # nosec B603


def inode(path: Path) -> str:
    value = path.stat()
    return f"{value.st_dev}:{value.st_ino}"


def identity(path: Path) -> dict:
    require(path.is_absolute() and not path.is_symlink(), "unsafe worktree path")
    path = path.resolve(strict=True)
    admin = Path(command(["git", "-C", str(path), "rev-parse", "--absolute-git-dir"]))
    common = Path(command(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"]))
    require(admin.resolve() != common.resolve(), "canonical repository cannot enroll")
    return {"path": str(path), "source_inode": inode(path), "admin": str(admin.resolve()),
            "admin_inode": inode(admin), "common": str(common.resolve())}


def initialize(connection: sqlite3.Connection) -> None:
    # Same database/transaction boundary as claim/transfer/remove; no second lease store.
    connection.execute("CREATE TABLE IF NOT EXISTS worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT NOT NULL)")
    # Static SQL identifiers; only record values are passed through parameters.
    for statement in (
        """CREATE TRIGGER IF NOT EXISTS managed_lifetime_fence_insert
            BEFORE INSERT ON worktree_owners
            WHEN EXISTS (SELECT 1 FROM worktree_managed_lifetimes WHERE path = NEW.worktree_path
                         AND json_extract(record, '$.state') = 'sealed')
                 AND NOT (COALESCE(NEW.task_id, '') = 'worktree-removal'
                          AND COALESCE(NEW.owner_session, '') GLOB 'cleanup:[0-9]*'
                          AND substr(NEW.owner_session, 9) NOT GLOB '*[^0-9]*')
            BEGIN SELECT RAISE(ABORT, 'managed worktree sealed for cleanup'); END""",
        """CREATE TRIGGER IF NOT EXISTS managed_lifetime_fence_update
            BEFORE UPDATE ON worktree_owners
            WHEN EXISTS (SELECT 1 FROM worktree_managed_lifetimes WHERE path = NEW.worktree_path
                         AND json_extract(record, '$.state') = 'sealed')
                 AND NOT (COALESCE(NEW.task_id, '') = 'worktree-removal'
                          AND COALESCE(NEW.owner_session, '') GLOB 'cleanup:[0-9]*'
                          AND substr(NEW.owner_session, 9) NOT GLOB '*[^0-9]*')
            BEGIN SELECT RAISE(ABORT, 'managed worktree sealed for cleanup'); END""",
    ):
        connection.execute(statement)
    idle_policy.initialize(connection)


def load(connection: sqlite3.Connection, path: str) -> dict:
    require(connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'worktree_owners'").fetchone()
            is not None, "ownership registry schema unavailable")
    if not connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (TABLE,)).fetchone():
        raise NotEnrolled("managed registry table absent")
    row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path = ?", (path,)).fetchone()
    if row is None:
        raise NotEnrolled("worktree is not enrolled")
    record = json.loads(row[0])
    require(record.get("schema") == 1 and record.get("manager") == "pulse", "invalid provenance")
    require(record["identity"]["path"] == path, "path mismatch")
    return record


def save(connection: sqlite3.Connection, record: dict) -> None:
    connection.execute("INSERT OR REPLACE INTO worktree_managed_lifetimes VALUES (?, ?)",
                       (record["identity"]["path"], json.dumps(record, sort_keys=True)))


def unit_snapshot(unit: str) -> dict:
    require(re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+(?:\.service)?", unit) is not None,
            "invalid worker unit")
    properties = ["Id", "LoadState", "ActiveState", "SubState", "MainPID", "InvocationID",
                  "ControlGroup", "ExitType", "RemainAfterExit", "Restart", "Result", "Job"]
    output = command(["systemctl", "--user", "show", unit, *[f"--property={p}" for p in properties]])
    snapshot = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    require(snapshot.get("LoadState") == "loaded", "unit evidence unavailable")
    require(snapshot.get("ExitType") == "cgroup" and snapshot.get("RemainAfterExit") == "yes"
            and snapshot.get("Restart") == "no", "unit lifetime contract mismatch")
    return snapshot


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def verify_identity(record: dict, path: Path) -> None:
    require(record["identity"] == identity(path), "worktree generation changed")


def enroll(connection: sqlite3.Connection, path: Path) -> None:
    observed = identity(path)
    require(connection.execute("SELECT 1 FROM worktree_managed_lifetimes WHERE path = ?", (str(path),)).fetchone() is None,
            "existing provenance cannot be overwritten")
    save(connection, {"schema": 1, "manager": "pulse", "generation": uuid.uuid4().hex,
                      "identity": observed, "state": "created", "launches": [], "created_at": time.time()})


def reserve(record: dict, unit: str) -> None:
    require(record["state"] in ("created", "running"), "launch already reserved or worktree sealed")
    if record["launches"]:
        drain(record["launches"][-1])
    require(re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+", unit) is not None, "invalid unit name")
    idle_policy.invalidate(record)
    record["launches"].append({"unit": unit, "boot_id": boot_id(), "invocation": None})
    record["state"] = "reserved"


def bind(record: dict) -> None:
    require(record["state"] == "reserved", "worker is not admitted")
    launch = record["launches"][-1]
    snapshot = unit_snapshot(launch["unit"])
    invocation = os.environ.get("INVOCATION_ID", "")
    require(re.fullmatch(r"[0-9a-f]{32}", invocation) is not None, "missing invocation identity")
    require(snapshot.get("InvocationID") == invocation and snapshot.get("MainPID") == str(os.getpid()),
            "worker does not own unit invocation")
    require(launch["boot_id"] == boot_id() and bool(snapshot.get("ControlGroup")), "missing cgroup identity")
    launch.update(invocation=invocation, cgroup=snapshot["ControlGroup"])
    idle_policy.invalidate(record)
    record["state"] = "running"


def drain(launch: dict) -> None:
    require(launch["boot_id"] == boot_id(), "boot generation unavailable")
    snapshot = unit_snapshot(launch["unit"])
    require(snapshot.get("InvocationID") == launch["invocation"], "invocation changed")
    require(snapshot.get("MainPID") == "0" and not snapshot.get("Job"), "unit still has work")
    require((snapshot.get("ActiveState"), snapshot.get("SubState")) in
            (("active", "exited"), ("failed", "failed")), "descendants have not drained")
    # ExitType=cgroup retains running state until the entire subtree exits.
    # Also check recursive kernel evidence when systemd has not removed the empty cgroup.
    cgroup = launch["cgroup"]
    require(cgroup.startswith("/") and ".." not in Path(cgroup).parts, "unsafe cgroup")
    directory = Path("/sys/fs/cgroup") / cgroup.lstrip("/")
    try:
        events = dict(line.split() for line in (directory / "cgroup.events").read_text().splitlines())
        require(events.get("populated") == "0", "cgroup remains populated")
    except FileNotFoundError:
        require(not directory.exists(), "cgroup evidence unavailable")
    require(unit_snapshot(launch["unit"]) == snapshot, "unit changed while sampling")
    launch["quiescence"] = snapshot


def seal(record: dict) -> None:
    if record["state"] == "sealed":
        return
    if record["state"] == "created":
        require(not record["launches"], "unexpected admission history")
        record["admission_cancelled"] = True
    elif record["state"] == "reserved":
        require(bool(record["launches"]) and record["launches"][-1]["invocation"] is None,
                "invocation already admitted")
        # Sealing and binding share BEGIN IMMEDIATE. A delayed systemd start
        # can still run the binder, but it cannot commit admission or exec work.
        record["launches"][-1]["admission_cancelled"] = True
    else:
        require(record["state"] == "running" and bool(record["launches"]), "unresolved launch")
        drain(record["launches"][-1])
    require(all(item.get("quiescence") or item.get("admission_cancelled") for item in record["launches"]),
            "unresolved earlier launch")
    record.update(state="sealed", sealed_at=time.time())


proof = lifetime_proof.proof


def idle_quiescence(record: dict) -> None:
    idle_policy.quiescence(record, boot_id, drain, seal)


def inspect_record(record: dict, path: Path, operation: str, extra: list[str], connection=None) -> None:
    if operation == "status":
        print(json.dumps(record, sort_keys=True))
        return
    if operation == "proof":
        lifetime_proof.inspect(record, path, extra, connection, verify_identity)
        return
    verify_identity(record, path)
    if operation in ("cleanup-ready", "idle-ready"):
        # Dry-run only: do not persist a seal before policy and owner checks.
        if operation == "idle-ready":
            require(len(extra) <= 1, "at most one idle window is accepted")
            idle_policy.owner_clear(connection, str(path))
            idle_policy.require_elapsed(record, boot_id(), int(extra[0]) if extra else idle_policy.IDLE_SECONDS)
            idle_quiescence(record)
        seal(record)
        return
    require(record["state"] in ("created", "running"), "worktree cannot be reused")
    if record["launches"]:
        drain(record["launches"][-1])


def observe_idle(connection, record: dict) -> None:
    try:
        idle_policy.observe(connection, record, boot_id(), idle_quiescence)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # The failed observation is evidence too. Persist invalidation under the
        # same writer lock rather than rolling back to a previously valid window.
        idle_policy.invalidate(record)
        save(connection, record)
        connection.execute("COMMIT")
        raise


def mutate_record(record: dict, path: Path, operation: str, extra: list[str], connection=None) -> None:
    verify_identity(record, path)
    if operation == "reserve":
        require(len(extra) == 1, "unit required")
        reserve(record, extra[0])
    elif operation == "bind-exec":
        require(bool(extra), "worker command required")
        bind(record)
    elif operation == "observe-idle":
        observe_idle(connection, record)
    else:
        if operation == "seal-idle":
            require(len(extra) <= 1, "at most one idle window is accepted")
            idle_policy.owner_clear(connection, str(path))
            idle_policy.require_elapsed(record, boot_id(), int(extra[0]) if extra else idle_policy.IDLE_SECONDS)
            idle_quiescence(record)
        seal(record)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("enroll", "reserve", "bind-exec", "seal", "proof", "status", "ready", "cleanup-ready",
                                             "observe-idle", "idle-ready", "seal-idle"))
    parser.add_argument("path")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    registry_dir = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    db = os.environ.get("WORKTREE_REGISTRY_DB") or str(registry_dir / "worktree-registry.db")
    path = Path(args.path)
    try:
        require(path.is_absolute() and str(path) == os.path.realpath(path), "canonical absolute path required")
        require(Path(db).is_file() and not Path(db).is_symlink(), "registry unavailable")
        readonly = args.operation in ("proof", "status", "ready", "cleanup-ready", "idle-ready")
        uri = Path(db).resolve().as_uri() + ("?mode=ro" if readonly else "?mode=rw")
        with closing(sqlite3.connect(uri, uri=True, timeout=10, isolation_level=None)) as connection:
            connection.execute("BEGIN" if readonly else "BEGIN IMMEDIATE")
            if not readonly:
                initialize(connection)
            if args.operation == "enroll":
                enroll(connection, path)
            else:
                record = load(connection, str(path))
                if readonly:
                    inspect_record(record, path, args.operation, args.extra, connection)
                else:
                    mutate_record(record, path, args.operation, args.extra, connection)
                    save(connection, record)
            connection.execute("COMMIT")
        # Do not stop units by name after sampling: systemd has no atomic
        # invocation-conditional StopUnit, so a replacement could be targeted.
        if args.operation == "bind-exec":
            os.environ["AIDEVOPS_MANAGED_WORKTREE"] = "pulse-cgroup-v1"
            # Intentional dispatcher-command execution, only after committed admission.
            # Local dispatcher argv, not issue content; no shell or privilege elevation.
            # nosemgrep: python.lang.security.audit.dangerous-os-exec-tainted-env-args.dangerous-os-exec-tainted-env-args
            os.execvp(args.extra[0], args.extra)  # nosec B606
        return 0
    except NotEnrolled:
        return 3
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "evidence unavailable"
        print(f"managed-worktree: {type(error).__name__}: {reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
