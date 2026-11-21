#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Release retained aidevops-worker-* user units after drained quiescence (GH#39702).

Managed launches keep their transient units (RemainAfterExit=yes) so readers
can sample a drained invocation. Without this sweep nothing releases them, and
the user manager keeps one unit per attempt.

A unit is released only when, in the current boot, it is drained by the same
criteria as drain_unit (matching invocation, MainPID=0, no job, active/exited
or failed/failed, unpopulated cgroup), and has stayed in that state for longer
than the grace period. Every registry launch that references it must match the
invocation. The drained sample is committed to worktree_unit_releases before the
unit is resampled and stopped. drain_unit accepts that receipt once the unit is
gone. Lifetime rows are never rewritten, so their equality guards still hold.

Units with processes (including active/running with MainPID=0 strays) are
never stopped; they are counted and retained. Receipts from earlier boots are
pruned because ended-boot receipts replace them.
"""

import argparse
from contextlib import closing
import copy
import json
from pathlib import Path
import random
import re
import sqlite3
import subprocess
import sys
import time

import worktree_lifetime_owner as owner
import worktree_lifetime_release_receipt as receipts

UNIT_PATTERN = re.compile(r"aidevops-worker-[A-Za-z0-9_-]+\.service")
GRACE_SECONDS = 3600
BULK_PROPERTIES = ("Id", "LoadState", "ActiveState", "SubState", "MainPID", "InvocationID", "ControlGroup",
                   "ExitType", "RemainAfterExit", "Restart", "Job", "StateChangeTimestampMonotonic")
CHUNK = 100
SAMPLE_ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


def systemctl(*args, check=True):
    # Fixed argv; unit names are validated against UNIT_PATTERN. No shell.
    return subprocess.run(["systemctl", "--user", *args], text=True, capture_output=True,  # nosec B603
                          timeout=30, check=check)


def list_units():
    result = systemctl("list-units", "--all", "--no-legend", "--plain", "--full", "aidevops-worker-*")
    names = (line.split()[0] for line in result.stdout.splitlines() if line.split())
    return [name for name in names if UNIT_PATTERN.fullmatch(name)]


def bulk_show(names):
    snapshots = {}
    for start in range(0, len(names), CHUNK):
        result = systemctl("show", *names[start:start + CHUNK], *[f"--property={p}" for p in BULK_PROPERTIES])
        for block in result.stdout.split("\n\n"):
            values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
            snapshots[values.get("Id", "")] = values
    return snapshots


def settled_for(snapshot):
    """Seconds since the last state change, or -1 when unavailable."""
    changed = snapshot.get("StateChangeTimestampMonotonic", "")
    if not changed.isdecimal() or int(changed) == 0:
        return -1
    return time.clock_gettime(time.CLOCK_MONOTONIC) - int(changed) / 1_000_000


def prefilter(snapshot, grace):
    """Cheap bulk classification: the first failing reason, or None for a candidate."""
    state = (snapshot.get("ActiveState"), snapshot.get("SubState"))
    checks = (
        ("not-loaded", snapshot.get("LoadState") == "loaded"),
        ("unmanaged-contract", (snapshot.get("ExitType"), snapshot.get("RemainAfterExit"),
                                snapshot.get("Restart")) == ("cgroup", "yes", "no")),
        ("live", snapshot.get("MainPID") == "0" and not snapshot.get("Job")),
        ("active-without-main-pid" if state[0] == "active" else "transitional", state in owner.DRAINED_STATES),
        ("invocation-unavailable", owner.valid_invocation(snapshot.get("InvocationID"))),
        ("timestamp-unavailable", settled_for(snapshot) >= 0),
        ("grace", settled_for(snapshot) >= grace),
    )
    return next((reason for reason, passed in checks if not passed), None)


def launch_units(raw):
    record = json.loads(raw)
    owner.require(isinstance(record, dict) and isinstance(record.get("launches", []), list),
                  "unreadable lifetime record")
    return [launch for launch in record.get("launches") or []
            if isinstance(launch, dict) and isinstance(launch.get("unit"), str)]


def references(db):
    """Map unit -> recorded launches. Any unreadable row fails the whole sweep closed."""
    with closing(receipts.connect(db, readonly=True)) as connection:
        connection.execute("BEGIN")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        owner.require("worktree_managed_lifetimes" in tables, "managed registry table absent")
        rows = connection.execute("SELECT record FROM worktree_managed_lifetimes").fetchall()
        if "worktree_lifetime_history" in tables:
            rows += connection.execute("SELECT record FROM worktree_lifetime_history").fetchall()
        connection.execute("COMMIT")
    found = {}
    for (raw,) in rows:
        for launch in launch_units(raw):
            found.setdefault(receipts.unit_id(launch["unit"]), []).append(copy.deepcopy(launch))
    return found


def drained_sample(unit, launches, current_boot):
    """Return the drained unit sample, or raise ValueError naming the refusal."""
    sample = owner.unit_snapshot(unit)
    invocation = sample.get("InvocationID")
    owner.require(owner.drained_snapshot_valid(sample, invocation), "descendants have not drained")
    for launch in launches:
        owner.require(launch.get("invocation") == invocation and launch.get("boot_id") == current_boot,
                      "reference mismatch")
        # The recorded launch's own drain rule, including its bound cgroup.
        owner.drain_unit(launch)
    if sample.get("ControlGroup"):
        owner.require_cgroup_drained(sample["ControlGroup"])
    owner.require(owner.unit_snapshot(unit) == sample, "unit changed while sampling")
    return sample


def stop_unit(unit, sample):
    """Resample, then stop: systemd has no invocation-conditional StopUnit."""
    current = owner.unit_snapshot(unit)
    owner.require(owner.drained_snapshot_valid(current, sample["InvocationID"]), "unit changed before release")
    if current.get("ActiveState") == "active":
        systemctl("stop", unit, check=False)
    systemctl("reset-failed", unit, check=False)
    # Garbage collection of the inactive transient unit can lag the stop reply.
    for _ in range(5):
        if receipts.unit_presence(unit).get("LoadState") == "not-found":
            return True
        time.sleep(0.1)
    return False


def release(db, unit, launches, current_boot, dry_run):
    """Release one candidate; return the summary key it counts under."""
    try:
        sample = drained_sample(unit, launches, current_boot)
    except SAMPLE_ERRORS:
        return "not-drained-or-mismatched"
    if dry_run:
        return "released"
    receipts.commit(db, unit, sample, current_boot, bool(launches))
    try:
        return "released" if stop_unit(unit, sample) else "release_pending"
    except SAMPLE_ERRORS:
        return "release_pending"


def sweep(db, limit, budget, grace, dry_run):
    deadline = time.monotonic() + budget
    current_boot = owner.boot_id()
    owner.require(owner.valid_boot_id(current_boot), "boot identity unavailable")
    summary = {"examined": 0, "released": 0, "release_pending": 0, "dry_run": dry_run, "retained": {}}
    retained = summary["retained"]
    names = list_units()
    summary["units"] = len(names)
    snapshots = bulk_show(names)
    refs = references(db)
    reasons = {name: prefilter(snapshots.get(name, {}), grace) for name in names}
    candidates = [name for name, reason in reasons.items() if reason is None]
    # Fair progress across passes when retained units outnumber the limit.
    random.shuffle(candidates)
    for reason in reasons.values():
        if reason:
            retained[reason] = retained.get(reason, 0) + 1
    for unit in candidates:
        outcome = "deferred"
        if summary["examined"] < limit and time.monotonic() < deadline:
            summary["examined"] += 1
            outcome = release(db, unit, refs.get(unit, []), current_boot, dry_run)
        if outcome in summary:
            summary[outcome] += 1
        else:
            retained[outcome] = retained.get(outcome, 0) + 1
    if not dry_run:
        summary["pruned_receipts"] = receipts.prune(db, current_boot)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("operation", choices=("sweep",))
    parser.add_argument("--limit", type=int, default=200, help="maximum units to release per pass")
    parser.add_argument("--budget-seconds", type=int, default=60)
    parser.add_argument("--grace-seconds", type=int, default=GRACE_SECONDS)
    parser.add_argument("--dry-run", action="store_true", help="report releasable units without changes")
    args = parser.parse_args()
    if sys.platform != "linux" or not Path("/proc/sys/kernel/random/boot_id").is_file():
        print(json.dumps({"status": "unsupported-platform"}))
        return 0
    try:
        owner.require(args.limit > 0 and args.budget_seconds > 0 and args.grace_seconds >= 0,
                      "limits must be positive")
        summary = sweep(receipts.registry_db(), args.limit, args.budget_seconds, args.grace_seconds, args.dry_run)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        # Fixed internal reasons only; never echo unit command output.
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(json.dumps({"status": "refused", "reason": reason}), file=sys.stderr)
        return 1
    print(json.dumps(dict(summary, status="ok"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
