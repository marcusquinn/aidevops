#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Observe lifecycle records; optionally reconcile verified, already-absent sources.

This is not deletion authorization. Reconciliation changes only final receipts in
the existing registry; it never removes a worktree, archive, or recovery copy.
"""

import argparse
from collections import Counter
from contextlib import closing
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

import worktree_lifetime_archive as archive


def registry_path():
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    return Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")


def presence(path):
    try:
        path.lstat()
        return "present"
    except FileNotFoundError:
        return "absent" if path.parent.is_dir() else "unavailable"
    except OSError:
        return "unavailable"


def records(limit, selected_paths=None):
    database = registry_path()
    result = {"status": "unavailable", "entries": [], "truncated": False}
    try:
        archive.require(database.is_file() and not database.is_symlink(), "registry unavailable")
        managed = archive.managed_module()
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)) as connection:
            connection.execute("BEGIN")
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (managed.TABLE,)).fetchone():
                result["status"] = "not-enrolled"
                return result
            total = connection.execute("SELECT COUNT(*) FROM worktree_managed_lifetimes").fetchone()[0]
            paths = (connection.execute("SELECT path FROM worktree_managed_lifetimes ORDER BY rowid DESC LIMIT ?", (limit,)).fetchall()
                     if selected_paths is None else [(name,) for name in selected_paths])
            result.update(status="available", total=total, truncated=total > len(paths))
            for (name,) in paths:
                entry = {"path": name, "evidence": "recorded-not-revalidated"}
                try:
                    record = managed.load(connection, name)
                    path = Path(name)
                    archive.require(path.is_absolute(), "invalid source path")
                    operation = record.get("archive_operation") or {}
                    idle = record.get("idle") or {}
                    archive.require(isinstance(operation, dict) and isinstance(idle, dict), "invalid lifecycle metadata")
                    archive.require(record["state"] in ("created", "reserved", "running", "sealed"), "invalid lifecycle state")
                    last_attempt = operation.get("last_reconcile_at")
                    archive.require(last_attempt is None or (type(last_attempt) in (int, float)
                                    and math.isfinite(last_attempt) and 0 <= last_attempt <= time.time()),
                                    "invalid reconciliation timestamp")
                    entry.update(state=record["state"], source=presence(path),
                                 phase=operation.get("phase"), archive=operation.get("archive"),
                                 operation_directory=operation.get("directory"),
                                 failure=operation.get("failure"),
                                 idle_observed_since=idle.get("since"),
                                 last_reconcile_at=last_attempt,
                                 reconcile_error=operation.get("reconcile_error"))
                except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
                    entry.update(state="unknown", error=type(error).__name__)
                result["entries"].append(entry)
    except (OSError, ValueError, sqlite3.Error) as error:
        result.update(status="unavailable", error=type(error).__name__)
    return result


def storage(path):
    result = {"path": str(path), "status": "unavailable", "bytes": None, "free_bytes": None}
    try:
        archive.require(path.is_dir() and not path.is_symlink(), "storage unavailable")
        result["free_bytes"] = shutil.disk_usage(path).free
        measured = subprocess.run(["du", "-sk", str(path)], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, timeout=2, check=True)
        result.update(status="observed", bytes=int(measured.stdout.split()[0]) * 1024)
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        pass
    return result


def scheduler():
    keys = ("LoadState", "ActiveState", "UnitFileState", "NextElapseUSecRealtime")
    try:
        observed = subprocess.run(["systemctl", "--user", "show", "aidevops-worktree-lifecycle.timer",
                                   *["--property=" + key for key in keys]], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, timeout=3, check=True)
        values = dict(line.split("=", 1) for line in observed.stdout.splitlines() if "=" in line)
        return {key: values.get(key) for key in keys}
    except (OSError, subprocess.SubprocessError):
        return {"status": "unavailable"}


def report(limit):
    home = Path.home()
    log_root = Path(os.environ.get("AIDEVOPS_LOG_DIR") or home / ".aidevops/logs")
    last_success = None
    try:
        value = int((log_root / "cleanup_worktrees.last-run").read_text().strip())
        if 0 < value <= time.time():
            last_success = value
    except (OSError, ValueError):
        pass
    return {"schema": "aidevops.worktree-lifecycle-status/v1", "observed_at": time.time(),
            "registry": records(limit), "cleanup_last_success": last_success, "scheduler": scheduler(),
            "storage": {
                "worktrees": storage(Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR") or home / "Git/_worktrees")),
                "archives": storage(Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT") or home / ".aidevops/recovery/archives")),
                "recovery": storage(home / ".aidevops/recovery"),
            }}


def reserve_scan(limit):
    """Advance a keyset cursor in the existing registry before attempting work.

    This is traversal metadata, not ownership or deletion evidence. Advancing
    across every reserved row prevents failures and ineligible records from
    monopolizing a bounded run. Concurrent callers reserve serially; crashes
    defer their batch until wraparound without changing any lifecycle receipt.
    """
    with archive.transaction() as connection:
        for table in ("worktree_managed_lifetimes", "worktree_owners"):
            archive.require(connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone(),
                            "managed registry unavailable")
        connection.execute("CREATE TABLE IF NOT EXISTS worktree_lifecycle_reconcile_cursor "
                           "(singleton INTEGER PRIMARY KEY CHECK(singleton=1), after_path TEXT NOT NULL)")
        previous = connection.execute("SELECT after_path FROM worktree_lifecycle_reconcile_cursor WHERE singleton=1").fetchone()
        after = previous[0] if previous else ""
        archive.require(isinstance(after, str), "invalid reconciliation cursor")
        rows = connection.execute("SELECT path FROM worktree_managed_lifetimes WHERE path > ? ORDER BY path LIMIT ?",
                                  (after, limit)).fetchall()
        if not rows and after:
            rows = connection.execute("SELECT path FROM worktree_managed_lifetimes ORDER BY path LIMIT ?", (limit,)).fetchall()
        if rows:
            archive.require(all(isinstance(row[0], str) for row in rows), "invalid registry path")
            connection.execute("INSERT OR REPLACE INTO worktree_lifecycle_reconcile_cursor VALUES (1, ?)", (rows[-1][0],))
        return [row[0] for row in rows]


def reconcile(limit, maximum):
    observed = records(limit, selected_paths=[])
    result = {"schema": "aidevops.worktree-lifecycle-reconcile/v1", "registry": observed["status"],
              "truncated": observed["truncated"], "examined": 0, "attempted": 0, "completed": 0, "deferred": 0}
    if observed["status"] != "available":
        return result
    try:
        paths = reserve_scan(min(limit, maximum))
        observed = records(limit, selected_paths=paths)
        result.update(registry=observed["status"], truncated=observed["truncated"], examined=len(paths))
    except (OSError, ValueError, sqlite3.Error) as error:
        result.update(registry="unavailable", error=type(error).__name__)
        return result
    candidates = [entry for entry in observed["entries"]
                  if entry.get("phase") == "verified" and entry.get("source") == "absent"]
    managed = archive.managed_module()
    for entry in candidates[:maximum]:
        path = Path(entry["path"])
        result["attempted"] += 1
        identifier = None
        failure = None
        try:
            archive.require(str(path) == os.path.realpath(path), "source identity changed")
            with archive.transaction() as connection:
                record = managed.load(connection, str(path))
                managed.idle_policy.owner_clear(connection, str(path))
                identifier = archive.operation(record)["id"]
            managed.proof(record, record["identity"]["source_inode"])
            archive.finish_removal(managed, path, record)
            result["completed"] += 1
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
            result["deferred"] += 1
            failure = type(error).__name__
        if identifier:
            try:
                archive.update(managed, path, identifier, {"last_reconcile_at": time.time(), "reconcile_error": failure})
            except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
                result["receipt_update_unavailable"] = True
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("report", "reconcile"))
    parser.add_argument("--limit", type=int, default=500)
    parser.add_argument("--max-attempts", type=int, default=5)
    parser.add_argument("--summary", action="store_true")
    arguments = parser.parse_args()
    if not 1 <= arguments.limit <= 1000 or not 1 <= arguments.max_attempts <= 20:
        parser.error("limit must be 1..1000 and max-attempts 1..20")
    value = report(arguments.limit) if arguments.operation == "report" else reconcile(arguments.limit, arguments.max_attempts)
    if arguments.summary and arguments.operation == "report":
        entries = value["registry"].pop("entries")
        value["registry"]["sampled_states"] = dict(Counter(entry.get("state", "unknown") for entry in entries))
    print(json.dumps(value, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
