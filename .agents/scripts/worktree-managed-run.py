#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run worktree-producing commands in a retained rootless user-service lifetime.

The command may create several worktrees through the shared creator. Completion
seals only their matching invocation records; it never adopts historical trees.
Optional post-seal callbacks run outside the completed unit, so archival does not
mistake a still-running producer for completed work. No sudo or detached fallback.
"""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

import worktree_lifetime_owner as lifetime
from worktree_managed_io import isolated_service_io


def backend_available():
    """Probe without starting a service; absence selects legacy before creation."""
    try:
        lifetime.require(sys.platform == "linux", "managed backend requires Linux")
        lifetime.require(Path("/sys/fs/cgroup/cgroup.controllers").is_file(), "cgroup v2 unavailable")
        lifetime.require(all(shutil.which(tool) for tool in ("systemd-run", "systemctl", "busctl")),
                         "managed backend tools unavailable")
        # systemctl may use the private manager socket while systemd-run uses
        # the session bus. Probe that bus, not just the manager's existence.
        payload = subprocess.check_output(
            ["busctl", "--user", "--json=short", "get-property", "org.freedesktop.systemd1",
             "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "Version"],
            text=True, stderr=subprocess.DEVNULL, timeout=3)
        version = json.loads(payload).get("data")
        lifetime.require(isinstance(version, str), "manager version unavailable")
        match = re.match(r"([0-9]+)", version)
        lifetime.require(match and int(match[1]) >= 250, "manager lacks required lifetime support")
        help_text = subprocess.check_output(
            ["systemd-run", "--help"], text=True, stderr=subprocess.DEVNULL, timeout=3)
        return "--expand-environment" in help_text
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        return False


def inherited_environment():
    # Forward values through systemd-run's inherited-variable form, not argv.
    # Do not forward old invocation IDs or parent runtime PIDs into the new unit.
    # Explicit generation/attempt admission requirements must remain mandatory.
    excluded = {"INVOCATION_ID", "SYSTEMD_EXEC_PID", "MANAGERPID", "NOTIFY_SOCKET",
                "WATCHDOG_PID", "WATCHDOG_USEC", "LISTEN_FDS", "LISTEN_PID", "LISTEN_FDNAMES",
                "JOURNAL_STREAM", "OPENCODE_PID", "CLAUDE_PID", "AIDEVOPS_WORKTREE_CREATING",
                "AIDEVOPS_LIFECYCLE_RUNTIME_PID", "AIDEVOPS_LIFECYCLE_SESSION_ID",
                "AIDEVOPS_WORKTREE_MANAGER", "AIDEVOPS_MANAGED_WORKTREE_RUN", "AIDEVOPS_MANAGED_WORKTREE_RUN_UNIT"}
    names = {key for key in os.environ if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)} - excluded
    return ["--setenv=" + key for key in sorted(names)]


def invocation_worktrees(unit, invocation):
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    db = Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")
    if not db.exists():
        return []  # A command which did not create a worktree needs no sealing.
    lifetime.require(db.is_file() and not db.is_symlink(), "unsafe worktree registry")
    with closing(sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)) as connection:
        if not connection.execute("SELECT 1 FROM sqlite_master WHERE name='worktree_managed_lifetimes'").fetchone():
            return []
        rows = connection.execute("""SELECT DISTINCT lifetimes.path, lifetimes.record
            FROM worktree_managed_lifetimes AS lifetimes, json_each(lifetimes.record, '$.launches') AS launches
            WHERE (json_extract(launches.value, '$.unit')=?
              AND json_extract(launches.value, '$.invocation')=?)
              OR json_extract(lifetimes.record, '$.creator_run')=?""", (unit, invocation, unit)).fetchall()
    return [(path, json.loads(record)) for path, record in rows]


def finalize(unit, snapshot, callback, deadline):
    scripts = Path(__file__).resolve().parent
    for path, record in invocation_worktrees(unit, snapshot["InvocationID"]):
        lifetime.require(record.get("manager") == lifetime.MANAGER, "unexpected managed run provenance")
        # Scratch trees may already have completed their guarded removal. Never
        # create a replacement just to seal a missing source.
        if not Path(path).exists():
            continue
        subprocess.run([sys.executable, str(scripts / "worktree-managed-lifetime.py"), "seal", path],
                       check=True, timeout=30)
        if callback:
            remaining = min(300, int(deadline - time.monotonic()))
            lifetime.require(remaining > 0, "post-seal budget exhausted; source retained")
            status = run([*callback, path], [], remaining, producer=False)
            lifetime.require(status == 0, "post-seal callback failed; inspect retained run")


def startup_snapshot(unit, client, invocation, deadline):
    """Distinguish pending admission from unavailable or replaced invocations."""
    try:
        snapshot = lifetime.unit_snapshot(unit)
    except (ValueError, subprocess.SubprocessError):
        if invocation is not None or time.monotonic() >= deadline or client.poll() is not None:
            raise
        return None
    if not invocation and not snapshot.get("InvocationID"):
        lifetime.require(time.monotonic() < deadline,
                         "managed invocation did not start within its startup budget")
        return None
    return snapshot


def wait_for_unit(unit, client, deadline, relay=lambda: None):
    startup_deadline = min(deadline, time.monotonic() + 10)
    invocation = None
    next_progress = time.monotonic() + 10
    while time.monotonic() < deadline:
        relay()
        snapshot = startup_snapshot(unit, client, invocation, startup_deadline)
        if snapshot is None:
            time.sleep(0.1)
            continue
        invocation = invocation or snapshot["InvocationID"]
        lifetime.require(snapshot["InvocationID"] == invocation,
                         "managed invocation changed")
        if snapshot.get("MainPID") == "0" and not snapshot.get("Job") and (
                snapshot.get("ActiveState"), snapshot.get("SubState")) in (
                    ("active", "exited"), ("failed", "failed")):
            return snapshot
        if time.monotonic() >= next_progress:
            print(f"Managed run {unit}: {snapshot.get('ActiveState')}/{snapshot.get('SubState')}; "
                  f"budget remaining {max(0, int(deadline-time.monotonic()))}s", file=sys.stderr, flush=True)
            next_progress = time.monotonic() + 10
        time.sleep(0.2)
    raise ValueError("managed run budget exhausted; RuntimeMaxSec bounds the owned unit")


def close_client(client):
    # The systemd-run --pipe/--pty client otherwise waits for a retained exited
    # unit forever. Signal only our Popen child, never a service selected by name.
    if client.poll() is None:
        client.terminate()
        try:
            client.wait(timeout=2)
        except subprocess.TimeoutExpired:
            client.kill()
            client.wait(timeout=2)


def run(command, callback, timeout, producer=True):
    lifetime.require(bool(command), "a command is required after --")
    lifetime.require(shutil.which("systemd-run") and shutil.which("systemctl"),
                     "rootless user-systemd is unavailable; no untracked fallback")
    subprocess.run(["systemctl", "--user", "show", "--property=Version"],
                   stdout=subprocess.DEVNULL, check=True, timeout=10)
    unit = "aidevops-worker-session-" + uuid.uuid4().hex + ".service"
    print(f"Managed worktree run: {unit}", file=sys.stderr, flush=True)
    deadline = time.monotonic() + timeout
    # A user service otherwise inherits its manager's mask, not the caller's.
    # Keep private caller modes private and ordinary archival modes unchanged.
    caller_umask = os.umask(0o077)
    os.umask(caller_umask)
    if producer:
        # Capture this service's native identity before any controlled creation.
        # Legacy invocation records remain scheduling hints, not removal proof.
        entry = Path(__file__).resolve().parent / "worker-lifecycle-state.sh"
        command = ["bash", str(entry), *command]
    with isolated_service_io() as (stdio, relay, mode):
        client = subprocess.Popen(
            ["systemd-run", "--user", "--no-ask-password", "--quiet", "--unit=" + unit, mode,
             *lifetime.SERVICE_PROPERTIES, "--property=RuntimeMaxSec=" + str(timeout),
             f"--property=UMask={caller_umask:04o}",
             "--property=TimeoutStopSec=5", "--expand-environment=no", *inherited_environment(),
             "--setenv=AIDEVOPS_MANAGED_WORKTREE_RUN=" + ("1" if producer else "0"),
             "--setenv=AIDEVOPS_MANAGED_WORKTREE_RUN_UNIT=" + unit,
             "--working-directory=" + os.getcwd(), "--", *command], **stdio)
        try:
            snapshot = wait_for_unit(unit, client, deadline, relay)
        finally:
            close_client(client)
    finalize(unit, snapshot, callback, deadline)
    # Retain the unit and its completion evidence. Never stop by name after a
    # snapshot: systemd has no invocation-conditional StopUnit operation.
    if snapshot.get("Result") == "success":
        return 0
    status = int(snapshot.get("ExecMainStatus") or "1")
    return (status or 1) if snapshot.get("ExecMainCode") == "1" else min(255, 128 + status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--after", action="append", default=[], metavar="ARG",
                        help="post-seal callback argv (repeat per argument); worktree path is appended")
    parser.add_argument("--timeout-seconds", type=int,
                        default=os.environ.get("AIDEVOPS_WORKTREE_RUN_TIMEOUT_SECONDS", "300"))
    parser.add_argument("--print-properties", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--check-backend", action="store_true",
                        help="check rootless managed-lifetime support without launching work")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.check_backend:
        return 0 if backend_available() else 1
    if args.print_properties:
        print("\n".join(lifetime.SERVICE_PROPERTIES))
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    try:
        lifetime.require(args.timeout_seconds > 0, "timeout must be positive")
        return run(command, args.after, args.timeout_seconds)
    except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
        # ValueError messages are fixed internal policy reasons. Never print
        # CalledProcessError argv: a user command could contain credentials.
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"Managed worktree run incomplete; sources and unit retained: {reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
