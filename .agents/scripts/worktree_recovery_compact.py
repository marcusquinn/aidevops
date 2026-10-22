#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run a rotating bounded compact/verify/retire pass using the existing lifecycle."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from worktree_lifetime_archive import require
from worktree_recovery_migration_state import load, private_directory, publish
from worktree_recovery_retry import SCHEMA as RETRY_SCHEMA, request_retry, revision, scheduled
from worktree_recovery_retry import FAILURE_DIAGNOSTIC_FIELDS

SCHEMA = "aidevops.worktree-recovery-compaction-pass/v1"


def candidates(root):
    names = {path.name for path in root.glob("aidevops-worktree-cleanup-*")}
    # A claimed bucket no longer exists at its original path. Keep its exact
    # journal in the rotation rather than abandoning interrupted retirement.
    for path in (root / ".compact-migrations").glob("*/retirement.json"):
        try:
            saved = load(path)
            if saved.get("authority") == "verified-git-changes/v1" and saved.get("phase") != "retired":
                names.add(path.parent.name)
            elif saved.get("phase") == "retired" and os.path.lexists(path.with_name("retry.json")):
                if load(path.with_name("retry.json"), RETRY_SCHEMA).get("status") != "completed":
                    names.add(path.parent.name)  # Reconcile a lost final hint, without reclaiming again.
        except (OSError, ValueError, KeyError):
            continue  # Unreadable journals never grant removal authority.
    require(len(names) <= 10000, "compaction:inventory-limit")
    return sorted(names)


def compact_one(root, name, timeout):
    bash = shutil.which("bash")
    require(bash is not None, "compaction:bash-unavailable")
    helper = Path(__file__).with_name("worktree-recovery-lifecycle-helper.sh")
    # The shared portable timeout owns the whole command group. A Python
    # subprocess timeout would kill only the shell, leaving its writer alive.
    command = 'source "$1" || exit 1; timeout_sec "$2" bash "$3" compact --bucket "$4"'
    result = subprocess.run([bash, "-c", command, "recovery-compaction",
                             str(helper.with_name("shared-constants.sh")), str(timeout),
                             str(helper), str(root / name)],
                            capture_output=True, text=True, check=False)
    if result.returncode == 124:
        return {"bucket": name, "retired": False, "reason": "compaction:deadline; transaction retained",
                "failure_code": "compaction:deadline", "failure_stage": "compact"}
    try:
        report = json.loads(result.stdout)
    except ValueError:
        report = {"reason": "compaction:evidence-unavailable"}
    retired = result.returncode == 0 and report.get("retired") is True
    return {"bucket": name, "retired": retired,
             "bucket_bytes": report.get("bucket_bytes", 0), "archive_bytes": report.get("archive_bytes", 0),
             "failure_code": None if retired else report.get("failure_code", "compaction:unknown-failure"),
             "failure_stage": None if retired else report.get("failure_stage", "compact"),
             **{key: report[key] for key in FAILURE_DIAGNOSTIC_FIELDS if key in report},
             "reason": "compaction:retired" if retired else report.get("reason", "compaction:retained")}


def run(root, state):
    require(root.is_absolute() and root == root.resolve() and not root.is_symlink(), "compaction:unsafe-root")
    private_directory(state)
    journal = state / "last.json"
    previous = load(journal, SCHEMA) if os.path.lexists(journal) else {}
    names = candidates(root)
    last = previous.get("cursor", "")
    ordered = [name for name in names if name > last] + [name for name in names if name <= last]
    result = {"schema": SCHEMA, "outcome": "no-candidates", "inventory_count": len(names),
              "cursor": last, "entries": [], "source_bytes_retired": 0, "archive_bytes": 0}
    deadline = time.monotonic() + 120
    migration_revision = revision()
    for name in ordered[:10]:
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        result.update(cursor=name, outcome="in-progress")
        publish(journal, result)  # Advance before IO so one blocked entry cannot starve the store.
        try:
            entry = scheduled(root, name, remaining, compact_one, migration_revision)
        except (OSError, ValueError, KeyError, TypeError):
            # Corrupt/symlinked scheduling data never permits work and cannot
            # starve unrelated entries in the rotating window.
            entry = {"bucket": name, "retired": False, "status": "blocked",
                     "reason": "compaction:schedule-invalid"}
        result["entries"].append(entry)
        if entry["retired"]:
            result.update(outcome="compacted", source_bytes_retired=entry["bucket_bytes"],
                          archive_bytes=entry["archive_bytes"])
            break  # At most one full-copy retirement per pass.
        result["outcome"] = "retained"
    publish(journal, result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--retry-bucket", help="Reset only this bucket's schedule; do not run compaction")
    args = parser.parse_args()
    try:
        if args.retry_bucket:
            require(args.root.is_absolute() and args.root == args.root.resolve()
                    and not args.root.is_symlink(), "compaction:unsafe-root")
            result = request_retry(args.root, args.retry_bucket, revision())
        else:
            result = run(args.root, args.state)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print(json.dumps({"schema": SCHEMA, "outcome": "failed", "reason": "compaction:evidence-unavailable"}))
        raise SystemExit(1)
