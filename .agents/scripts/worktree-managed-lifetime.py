#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Rootless, cooperative Pulse worktree lifetime evidence in the existing registry.

Only newly created dispatcher worktrees enroll. No inference from branch names,
missing owner rows, dead wrapper PIDs, or missing systemd units grants authority.
Workers must not hand work to an untracked service or external process.

One record is one worktree generation; each launch entry is one execution
attempt (reserve -> bind-exec -> drained quiescence). Sealing is terminal for
the generation and is never reopened. Sequential resume reserves another
attempt only from running after the previous invocation drained. Provenance is
launcher classification, not actor identity, and never deletion authority.
Same-UID cgroup accounting is evidence, not a sandbox against hostile processes.
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
import worktree_lifetime_launch as launch_contract
import worktree_lifetime_proof as lifetime_proof
import worktree_lifetime_owner as owner_lifetime


TABLE = "worktree_managed_lifetimes"
BACKEND = launch_contract.BACKEND
TaskMismatch = launch_contract.TaskMismatch
SealedGeneration = launch_contract.SealedGeneration


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
    return owner_lifetime.identity(path)


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
    require(record.get("schema") == 1 and record.get("manager") in ("pulse", owner_lifetime.MANAGER),
            "invalid provenance")
    require(record["identity"]["path"] == path, "path mismatch")
    return record


def save(connection: sqlite3.Connection, record: dict) -> None:
    connection.execute("INSERT OR REPLACE INTO worktree_managed_lifetimes VALUES (?, ?)",
                       (record["identity"]["path"], json.dumps(record, sort_keys=True)))


def unit_snapshot(unit: str) -> dict:
    return owner_lifetime.unit_snapshot(unit)


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def verify_identity(record: dict, path: Path) -> None:
    require(record["identity"] == identity(path), "worktree generation changed")


def enroll(connection: sqlite3.Connection, path: Path) -> None:
    observed = identity(path)
    require(connection.execute("SELECT 1 FROM worktree_managed_lifetimes WHERE path = ?", (str(path),)).fetchone() is None,
            "existing provenance cannot be overwritten")
    # Additive fields: older readers ignore them; absence means "unrecorded",
    # never a matching task or a known trigger.
    save(connection, {"schema": 1, "manager": "pulse", "generation": uuid.uuid4().hex,
                      "identity": observed, "state": "created", "launches": [], "created_at": time.time(),
                      "created_by": launch_contract.provenance(), "task": launch_contract.task_identity()})


def reserve(record: dict, unit: str) -> None:
    require(record.get("manager") == "pulse", "owner-observed worktree cannot change admission mode")
    launch_contract.check_generation(record)
    require(record["state"] in ("created", "running"), "launch already reserved or worktree sealed")
    if record["launches"]:
        drain(record["launches"][-1])
    require(re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+", unit) is not None, "invalid unit name")
    idle_policy.invalidate(record)
    record["launches"].append(launch_contract.attempt(record["launches"], unit, boot_id()))
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
    launch.update(invocation=invocation, cgroup=snapshot["ControlGroup"], bound_at=time.time())
    idle_policy.invalidate(record)
    record["state"] = "running"


def drain(launch: dict) -> None:
    if launch.get("kind") == owner_lifetime.KIND:
        owner_lifetime.drain(launch)
        return
    owner_lifetime.drain_unit(launch, boot_id, unit_snapshot)


def seal(record: dict) -> None:
    if record.get("manager") == owner_lifetime.MANAGER:
        require(bool(record["launches"]), "missing owner admission evidence")
        owner_lifetime.require_admission_observed(record)
        for launch in record["launches"]:
            owner_lifetime.drain(launch)
        record.update(state="sealed", sealed_at=time.time())
        return
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


def print_status(record: dict, path: Path, extra: list[str], connection=None) -> None:
    print(json.dumps(record, sort_keys=True))


def print_proof(record: dict, path: Path, extra: list[str], connection=None) -> None:
    lifetime_proof.inspect(record, path, extra, connection, verify_identity)


def print_match(record: dict, path: Path, extra: list[str], connection=None) -> None:
    # Generation the launcher must present at reservation; sealed never matches.
    verify_identity(record, path)
    print(launch_contract.match(record, extra))


READERS = {"status": print_status, "proof": print_proof, "match": print_match}


def inspect_record(record: dict, path: Path, operation: str, extra: list[str], connection=None) -> None:
    reader = READERS.get(operation)
    if reader:
        reader(record, path, extra, connection)
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
                                             "observe-idle", "idle-ready", "seal-idle", "match"))
    parser.add_argument("path")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    registry_dir = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    db = os.environ.get("WORKTREE_REGISTRY_DB") or str(registry_dir / "worktree-registry.db")
    path = Path(args.path)
    try:
        require(path.is_absolute() and str(path) == os.path.realpath(path), "canonical absolute path required")
        require(Path(db).is_file() and not Path(db).is_symlink(), "registry unavailable")
        readonly = args.operation in ("proof", "status", "ready", "cleanup-ready", "idle-ready", "match")
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
        # Reuse refusals keep stable codes: 4 different task, 5 sealed generation.
        return getattr(error, "exit_code", 1)


if __name__ == "__main__":
    sys.exit(main())
