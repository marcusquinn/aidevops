#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Rootless owner-cgroup observations, not synthetic systemd completion receipts.

PID completion is reconciled separately from containment. Managed invocations
retain their systemd completion contract. Without that contract, a legacy
parent's completion permits removal only after its recorded boot has ended.
An empty, missing or replaced arbitrary cgroup is not descendant evidence.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


MANAGER = "owner-cgroup"
KIND = "owner-cgroup-v1"
ROOT = Path("/sys/fs/cgroup")
SERVICE_PROPERTIES = ("--property=Type=exec", "--property=ExitType=cgroup",
                      "--property=RemainAfterExit=yes", "--property=Restart=no",
                      "--property=KillMode=control-group")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def inode(path):
    observed = path.stat()
    return f"{observed.st_dev}:{observed.st_ino}"


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def unit_snapshot(unit):
    require(re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+(?:\.service)?", unit) is not None,
            "invalid worker unit")
    properties = ("Id", "LoadState", "ActiveState", "SubState", "MainPID", "InvocationID",
                  "ControlGroup", "ExitType", "RemainAfterExit", "Restart", "Result", "Job",
                  "ExecMainCode", "ExecMainStatus")
    output = subprocess.check_output(
        ["systemctl", "--user", "show", unit, *[f"--property={p}" for p in properties]],
        text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    snapshot = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    require(snapshot.get("LoadState") == "loaded", "unit evidence unavailable")
    require(snapshot.get("ExitType") == "cgroup" and snapshot.get("RemainAfterExit") == "yes"
            and snapshot.get("Restart") == "no", "unit lifetime contract mismatch")
    return snapshot


def drain_unit(launch, boot_reader=boot_id, snapshot_reader=unit_snapshot):
    require(launch["boot_id"] == boot_reader(), "boot generation unavailable")
    snapshot = snapshot_reader(launch["unit"])
    require(snapshot.get("InvocationID") == launch["invocation"], "invocation changed")
    require(snapshot.get("MainPID") == "0" and not snapshot.get("Job"), "unit still has work")
    require((snapshot.get("ActiveState"), snapshot.get("SubState")) in
            (("active", "exited"), ("failed", "failed")), "descendants have not drained")
    cgroup = launch["cgroup"]
    require(cgroup.startswith("/") and ".." not in Path(cgroup).parts, "unsafe cgroup")
    directory = ROOT / cgroup.lstrip("/")
    try:
        events = dict(line.split() for line in (directory / "cgroup.events").read_text().splitlines())
        require(events.get("populated") == "0", "cgroup remains populated")
    except FileNotFoundError:
        require(not directory.exists(), "cgroup evidence unavailable")
    require(snapshot_reader(launch["unit"]) == snapshot, "unit changed while sampling")
    launch["quiescence"] = snapshot


def identity(path):
    """Same physical identity for every producer and lifetime manager."""
    require(path.is_absolute() and not path.is_symlink(), "unsafe worktree path")
    path = path.resolve(strict=True)
    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", *args],
            stderr=subprocess.DEVNULL, text=True, timeout=10).strip()
    admin = Path(git("--absolute-git-dir")).resolve(strict=True)
    common = Path(git("--path-format=absolute", "--git-common-dir")).resolve(strict=True)
    require(admin != common, "canonical repository cannot enroll")
    return {"path": str(path), "source_inode": inode(path), "admin": str(admin),
            "admin_inode": inode(admin), "common": str(common)}


def process_identity(pid):
    proc = Path("/proc") / str(pid)
    require(proc.stat().st_uid == os.getuid(), "owner UID mismatch")
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    require(fields[0] not in ("Z", "X"), "owner already exited")
    return fields[19]


def recorded_process_status(launch):
    """Observe one saved process generation, never authorize source removal.

    A dead parent in the current boot says nothing about surviving descendants.
    Reading only the recorded PID avoids global CWD visibility requirements.
    """
    result = {"status": "unknown", "descendants": "unknown"}
    try:
        saved_boot = launch.get("boot_id")
        current_boot = boot_id()
        require(isinstance(saved_boot, str) and
                re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", saved_boot) is not None,
                "invalid saved boot identity")
        require(isinstance(current_boot, str) and
                re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", current_boot) is not None,
                "boot identity unavailable")
        pid = launch.get("owner_pid")
        start = launch.get("owner_start")
        require(type(pid) is int and pid > 0 and isinstance(start, str) and start.isdecimal(),
                "invalid saved process identity")
        if saved_boot != current_boot:
            return {"status": "previous-boot", "descendants": "previous-boot-ended"}
        try:
            observed = process_identity(pid)
            result["status"] = "same-process-alive" if observed == start else "pid-reused"
        except FileNotFoundError:
            # ENOENT reading stat alone can be a race or unavailable procfs.
            # Require the process entry to be absent under a readable proc root.
            require(Path("/proc/self/stat").is_file(), "procfs unavailable")
            require(not os.path.lexists(Path("/proc") / str(pid)), "process identity unavailable")
            result["status"] = "pid-absent"
        require(boot_id() == current_boot, "boot changed during observation")
    except (OSError, ValueError, IndexError, TypeError, AttributeError):
        result = {"status": "unknown", "descendants": "unknown"}
    return result


def observe(pid, session):
    observation = {"kind": KIND, "owner_pid": pid, "owner_session": session,
                   "observed_at": time.time(), "evidence": "unavailable"}
    try:
        start = process_identity(pid)
        namespace = inode(Path("/proc/self/ns/cgroup"))
        require(inode(Path(f"/proc/{pid}/ns/cgroup")) == namespace,
                "owner cgroup namespace mismatch")
        entries = Path(f"/proc/{pid}/cgroup").read_text().splitlines()
        paths = [line[3:] for line in entries if line.startswith("0::")]
        require(len(paths) == 1, "cgroup v2 unavailable")
        name = paths[0]
        require(name.startswith("/") and ".." not in Path(name).parts and name != "/",
                "unbounded owner cgroup")
        group = ROOT / name.lstrip("/")
        require(group.resolve(strict=True) == group, "unsafe cgroup path")
        group_inode = inode(group)
        require("populated 1" in (group / "cgroup.events").read_text().splitlines(),
                "owner cgroup not populated")
        require(process_identity(pid) == start and
                Path(f"/proc/{pid}/cgroup").read_text().splitlines() == entries and
                inode(group) == group_inode, "owner changed during observation")
        observation.update(evidence="observed", boot_id=boot_id(), owner_start=start,
                           cgroup=name, cgroup_inode=group_inode, namespace=namespace)
        unit = Path(name).name
        snapshot = unit_snapshot(unit)
        require(snapshot.get("MainPID") == str(pid) and snapshot.get("ControlGroup") == name,
                "owner is not the managed invocation leader")
        invocation = os.environ.get("INVOCATION_ID", "")
        require(re.fullmatch(r"[0-9a-f]{32}", invocation) is not None and
                snapshot.get("InvocationID") == invocation, "unmanaged creation admission")
        require(process_identity(pid) == start and unit_snapshot(unit) == snapshot,
                "invocation changed during enrollment")
        observation.update(unit=unit, invocation=invocation, completion_evidence="systemd-cgroup-v1")
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        observation["reason"] = "owner-descendant-evidence-unavailable"
    return observation


def drain(launch):
    if launch.get("completion_evidence") is None:
        from worktree_lifetime_reconcile import quiescence
        launch["observation_quiescence"] = quiescence(launch)
        return
    require(launch.get("completion_evidence") == "systemd-cgroup-v1",
            "owner has no managed descendant-completion contract")
    drain_unit(launch)


def require_admission_observed(record):
    require(type(record.get("admission_epoch")) is int and
            record["admission_epoch"] == record.get("observed_admission_epoch"),
            "ownership changed without process admission evidence")


def begin_creation(connection, path):
    """Fence old receipts durably BEFORE Git can recreate or reuse any inode."""
    if not connection.execute("SELECT 1 FROM sqlite_master WHERE name='worktree_managed_lifetimes'").fetchone():
        return ""
    row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path=?", (path,)).fetchone()
    if row is None:
        return ""
    record = json.loads(row[0])
    require(record.get("manager") == MANAGER, "different lifetime manager owns this path")
    record.pop("creation_pending", None)
    from worktree_lifetime_proof import proof
    proof(record, record["identity"]["source_inode"])
    token = uuid.uuid4().hex
    record["creation_pending"] = token
    connection.execute("UPDATE worktree_managed_lifetimes SET record=? WHERE path=?",
                       (json.dumps(record), path))
    return token


def prepare_creation(connection, path):
    """Consume a pre-Git fence atomically with registration; never infer freshness from inode numbers."""
    if not connection.execute("SELECT 1 FROM sqlite_master WHERE name='worktree_managed_lifetimes'").fetchone():
        return
    row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path=?", (path,)).fetchone()
    if row is None:
        return
    record = json.loads(row[0])
    require(record.get("manager") == MANAGER, "different lifetime manager owns this path")
    token = record.pop("creation_pending", None)
    require(bool(token) and token == os.environ.get("AIDEVOPS_WORKTREE_CREATION_TOKEN"),
            "replacement has no matching pre-creation fence")
    from worktree_lifetime_proof import proof
    proof(record, record["identity"]["source_inode"])
    require(re.fullmatch(r"[0-9a-f]{32}", record.get("generation", "")) is not None,
            "missing generation identity")
    connection.execute("""CREATE TABLE IF NOT EXISTS worktree_lifetime_history (
        path TEXT NOT NULL, generation TEXT NOT NULL, record TEXT NOT NULL,
        replaced_at REAL NOT NULL, PRIMARY KEY(path, generation))""")
    connection.execute("INSERT INTO worktree_lifetime_history VALUES (?, ?, ?, ?)",
                       (path, record["generation"], json.dumps(record), time.time()))
    connection.execute("DELETE FROM worktree_managed_lifetimes WHERE path=?", (path,))


def check_admission(connection, path):
    if not connection.execute("SELECT 1 FROM sqlite_master WHERE name='worktree_managed_lifetimes'").fetchone():
        return
    row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path=?", (path,)).fetchone()
    if row:
        record = json.loads(row[0])
        if record.get("manager") == MANAGER:
            require_admission_observed(record)


def initialize_admission(connection):
    # Even a legacy SQL writer cannot silently admit an unobserved new owner.
    # The normal Python ownership transaction observes and acknowledges its own
    # transition before COMMIT. An out-of-band change invalidates future proof.
    for event in ("INSERT", "UPDATE"):
        changed = ("AND (OLD.owner_pid IS NOT NEW.owner_pid OR "
                   "OLD.owner_session IS NOT NEW.owner_session OR "
                   "OLD.owner_process_start IS NOT NEW.owner_process_start)" if event == "UPDATE" else "")
        connection.execute(f"""CREATE TRIGGER IF NOT EXISTS owner_admission_{event.lower()}
            AFTER {event} ON worktree_owners
            WHEN NOT (COALESCE(NEW.task_id, '') = 'worktree-removal'
                AND COALESCE(NEW.owner_session, '') GLOB 'cleanup:[0-9]*'
                AND substr(NEW.owner_session, 9) NOT GLOB '*[^0-9]*')
            {changed}
            BEGIN UPDATE worktree_managed_lifetimes
                SET record=json_set(record, '$.admission_epoch',
                    COALESCE(json_extract(record, '$.admission_epoch'), 0) + 1)
                WHERE path=NEW.worktree_path AND json_extract(record, '$.manager')='owner-cgroup';
            END""")
    connection.execute("""CREATE TRIGGER IF NOT EXISTS owner_admission_path_update
        AFTER UPDATE OF worktree_path ON worktree_owners
        WHEN OLD.worktree_path IS NOT NEW.worktree_path
        BEGIN UPDATE worktree_managed_lifetimes
            SET record=json_set(record, '$.admission_epoch',
                COALESCE(json_extract(record, '$.admission_epoch'), 0) + 1)
            WHERE path IN (OLD.worktree_path, NEW.worktree_path)
                AND json_extract(record, '$.manager')='owner-cgroup';
        END""")


def register(connection, path, pid, session, creating=False):
    """Called inside the ownership transaction, including ownership transfers."""
    connection.execute("CREATE TABLE IF NOT EXISTS worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT NOT NULL)")
    row = connection.execute("SELECT record FROM worktree_managed_lifetimes WHERE path=?", (path,)).fetchone()
    if row is None and not creating:
        return  # Never manufacture provenance for an existing legacy worktree.
    if row is None and (sys.platform == "darwin" or
                        os.environ.get("AIDEVOPS_WORKTREE_MANAGER") == "legacy-guards"):
        # Preserve the existing macOS/legacy guard contract, not a synthetic
        # managed completion receipt. Existing managed rows NEVER take this path.
        connection.execute("CREATE TABLE IF NOT EXISTS worktree_creation_backends (path TEXT PRIMARY KEY, record TEXT NOT NULL)")
        record = {"schema": 1, "backend": "legacy-guards", "identity": identity(Path(path)),
                  "created_at": time.time(), "generation": uuid.uuid4().hex}
        connection.execute("INSERT OR REPLACE INTO worktree_creation_backends VALUES (?, ?)",
                           (path, json.dumps(record, sort_keys=True)))
        return
    initialize_admission(connection)
    if row:
        record = json.loads(row[0])
        if record.get("manager") != MANAGER:
            return  # Pulse's admission and systemd receipt contract stays separate.
        require(record["state"] != "sealed", "worktree admission sealed")
        require(record["identity"] == identity(Path(path)), "worktree generation changed")
    else:
        record = {"schema": 1, "manager": MANAGER, "generation": uuid.uuid4().hex,
                  "identity": identity(Path(path)), "state": "running", "launches": [],
                  "created_at": time.time(), "admission_epoch": 0,
                  "creator_run": os.environ.get("AIDEVOPS_MANAGED_WORKTREE_RUN_UNIT", "")}
    launch = observe(pid, session)
    # Repeated registration is idempotent only for the same observed process
    # generation and containment. Unknown observations must not erase history.
    keys = ("owner_pid", "owner_session", "owner_start", "boot_id", "cgroup", "cgroup_inode", "namespace",
            "unit", "invocation", "completion_evidence")
    if not any(all(old.get(key) == launch.get(key) for key in keys) for old in record["launches"]):
        record["launches"].append(launch)
    record.pop("idle", None)
    record["ownership_epoch"] = record.get("ownership_epoch", 0) + 1
    record["observed_admission_epoch"] = record["admission_epoch"]
    from worktree_lifetime_reconcile import reconcile
    reconcile(record)
    connection.execute("INSERT OR REPLACE INTO worktree_managed_lifetimes VALUES (?, ?)",
                       (path, json.dumps(record, sort_keys=True)))
