#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fast, read-only legacy eligibility statistics; never deletion authority.

Only direct-child bucket metadata is read. No Git, network, process scanning,
recursive sizing, source hashing, archive creation or restoration is performed.
An exact dispatch pathname is a useful lead, NOT proof of the archived generation.
"""

import argparse
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
from itertools import islice
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time


RETENTION_SECONDS = 7 * 24 * 60 * 60
MAX_BUCKETS = 10000
FIELDS = ("format", "archive-complete", "created-at", "source-real",
          "source-inode", "source-removal-outcome", "producer", "producer-context")
# pulse-dispatch-worker-launch.sh: _dlw_precreate_worktree generates
# feature/auto-$(date +%Y%m%d-%H%M%S)-gh${issue_number}; worktree-paths.sh
# aidevops_generate_worktree_path prefixes the repo name and replaces '/' with '-'.
PULSE_SOURCE_NAME = re.compile(r".+-feature-auto-([0-9]{8}-[0-9]{6})-gh[1-9][0-9]*")


def legacy_origin(source_path, producer, context):
    """Classify by the dispatcher's naming convention, not lifecycle proof."""
    if producer == "profile-readme-helper.sh":
        return "profile"
    if producer != "worktree-helper.sh" or context != "recoverable-cleanup":
        return "unknown"
    match = PULSE_SOURCE_NAME.fullmatch(Path(source_path).name)
    if match is None or not Path(source_path).is_absolute():
        return "unknown"
    try:
        datetime.strptime(match[1], "%Y%m%d-%H%M%S")
    except ValueError:
        return "unknown"
    return "pulse"


def legacy_decision(origin, age_seconds, has_lifecycle=False):
    """Apply retention after classification; this is not deletion authorization."""
    if has_lifecycle:
        return "lifecycle-path"
    if origin == "profile":
        return "non-pulse-profile"
    if origin != "pulse":
        return "manual-origin" if origin == "manual" else "unknown-origin"
    if age_seconds is None or age_seconds < 0:
        return "missing-timestamp"
    return "within-retention" if age_seconds < RETENTION_SECONDS else "eligible-legacy-pulse"


def read_small(path, limit=8192):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        observed = os.fstat(handle.fileno())
        if not stat.S_ISREG(observed.st_mode) or observed.st_size > limit:
            raise ValueError("unsafe-or-oversized-metadata")
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError("oversized-metadata")
    return data.decode("utf-8")


def registry_records(path):
    try:
        if path.is_symlink() or not path.is_file():
            raise ValueError("registry-unavailable")
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            rows = db.execute("SELECT path,record FROM worktree_managed_lifetimes LIMIT 10001").fetchall()
        if len(rows) > MAX_BUCKETS:
            raise ValueError("registry-limit")
        return {name: json.loads(record) for name, record in rows}, "available"
    except (OSError, ValueError, sqlite3.Error):
        return {}, "unavailable"


def dispatch_paths(path):
    try:
        rows = [json.loads(line) for line in read_small(path, 16 * 1024 * 1024).splitlines() if line]
        return {row["worktree_path"] for row in rows if isinstance(row.get("worktree_path"), str)}, "available"
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return set(), "unavailable"


def age_seconds(created_at, now):
    try:
        created = datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        age = now - created.timestamp()
        return age if age >= 0 else None
    except (ValueError, OverflowError):
        return None


def inspect_bucket(bucket, records, paths, now):
    metadata = bucket / ".aidevops-worktree-recovery"
    try:
        if bucket.is_symlink() or metadata.is_symlink() or not metadata.is_dir():
            raise ValueError("unsafe-metadata")
        values = {name: read_small(metadata / name).strip() for name in FIELDS}
        if values["format"] != "aidevops-worktree-recovery-v2" or values["archive-complete"] != values["format"]:
            raise ValueError("incomplete-or-unsupported-metadata")
        if values["source-removal-outcome"] != "removed":
            raise ValueError("source-removal-incomplete")
    except (OSError, UnicodeError):
        return {"reason": "metadata-unavailable", "age": "unavailable"}
    except ValueError as error:
        return {"reason": str(error), "age": "unavailable"}
    age = age_seconds(values["created-at"], now)
    record = records.get(values["source-real"], {})
    identity = record.get("identity", {})
    matched = (record.get("manager") == "pulse" and record.get("schema") == 1
               and identity.get("path") == values["source-real"]
               and identity.get("source_inode") == values["source-inode"])
    origin = legacy_origin(values["source-real"], values["producer"], values["producer-context"])
    # Any existing lifecycle row uses that path, even if its generation mismatches.
    reason = legacy_decision(origin, age, has_lifecycle=values["source-real"] in records)
    return {"reason": reason, "age": "unavailable" if age is None else
             ("at-least-7-days" if age >= RETENTION_SECONDS else "under-7-days"),
              "origin_basis": "pulse-dispatch-name" if origin == "pulse" else origin,
             "dispatch_path_match": values["source-real"] in paths,
             "source_path": values["source-real"], "source_inode": values["source-inode"],
             "created_at": values["created-at"],
             "lifecycle_state": record.get("state") if matched else None,
            "producer": values["producer"], "producer_context": values["producer-context"]}


def report(root, registry, ledger, details=False):
    started = time.monotonic()
    now = time.time()
    if root.is_symlink() or not root.is_dir():
        raise ValueError("recovery-root-unavailable")
    records, registry_status = registry_records(registry)
    paths, ledger_status = dispatch_paths(ledger)
    with os.scandir(root) as entries:
        buckets = list(islice((Path(e.path) for e in entries
                              if e.name.startswith("aidevops-worktree-cleanup-")), MAX_BUCKETS + 1))
    results = [inspect_bucket(bucket, records, paths, now) for bucket in buckets[:MAX_BUCKETS]]
    summary = {"schema": "aidevops.recovery-legacy-report/v1", "read_only": True,
            "scope": str(root), "observed_at": now, "retention_days": 7,
            "inventory_complete": len(buckets) <= MAX_BUCKETS,
            "registry_status": registry_status, "dispatch_ledger_status": ledger_status,
            "bucket_count": len(results), "reasons": dict(Counter(r["reason"] for r in results)),
            "ages": dict(Counter(r["age"] for r in results)),
            "lifecycle_states": dict(Counter(r["lifecycle_state"] for r in results if r.get("lifecycle_state"))),
            "dispatch_path_matches_not_origin_proof": sum(r.get("dispatch_path_match", False) for r in results),
            "producers": dict(Counter(r["producer"] for r in results if r.get("producer"))),
            "at_least_7_days_by_producer": dict(Counter(r["producer"] for r in results
                                                       if r["age"] == "at-least-7-days")),
            "producer_contexts": dict(Counter(r["producer_context"] for r in results if r.get("producer_context"))),
            "eligible_legacy_pulse": sum(r["reason"] == "eligible-legacy-pulse" for r in results),
            "deletion_authorized": False, "bytes_measured": False,
            "elapsed_ms": round((time.monotonic() - started) * 1000, 3)}
    if details:
        summary["entries"] = [{"bucket": str(bucket), **result} for bucket, result in zip(buckets, results)]
    return summary


def main():
    workspace = Path.home() / ".aidevops/.agent-workspace"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / ".aidevops/recovery/worktrees")
    parser.add_argument("--registry", type=Path, default=workspace / "worktree-registry.db")
    parser.add_argument("--ledger", type=Path, default=workspace / "tmp/dispatch-ledger.jsonl")
    parser.add_argument("--details", action="store_true", help="Include local bucket/source paths and reasons")
    args = parser.parse_args()
    try:
        print(json.dumps(report(args.root, args.registry, args.ledger, args.details), sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, AttributeError):
        print(json.dumps({"read_only": True, "error": "report-evidence-unavailable", "deletion_authorized": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
