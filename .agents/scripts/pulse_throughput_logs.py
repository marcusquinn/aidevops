"""Streaming readers for Pulse dispatch, ceremony and worker-runtime logs."""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from collections import defaultdict
from datetime import datetime, timezone
import json
import math

CEREMONY_STAGES = (
    "dedup.ceremony_total", "dedup.worker_launch_total", "dedup.dedup_check",
    "dedup.precreate_worktree", "dedup.claim_consensus",
)


def iso_time(value):
    """Naive ISO timestamps mean UTC, independently of the host timezone."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).timestamp()


def lines(path):
    """Stream logs; absence, rotation or unreadability is non-fatal."""
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            yield from stream
    except OSError:
        return


def tsv_rows(path, columns, duration_column):
    for line in lines(path):
        row = line.rstrip("\n").split("\t")
        if len(row) < columns:
            continue
        try:
            timestamp = iso_time(row[0])
            duration = float(row[duration_column])
        except (ValueError, OverflowError):
            continue
        if math.isfinite(duration) and duration >= 0:
            yield timestamp, duration, row


def dispatch_metrics(log_dir, since, until):
    spawns = defaultdict(list)
    spawn_count = 0
    dispatch_seen = False
    costs = defaultdict(list)
    for timestamp, milliseconds, row in tsv_rows(log_dir / "dispatch-stages.tsv", 6, 4):
        in_window = since <= timestamp < until
        dispatch_seen |= in_window
        if row[5] != "complete":
            continue
        # Same look-ahead as runtime_exits, so a later retry's exit pairs with
        # its own spawn; interval guards still drop spawns at or after until.
        if row[3] == "dedup.worker_spawn" and since - 21600 <= timestamp < until + 21600:
            spawns[row[1].lstrip("#")].append(timestamp)
            spawn_count += int(in_window)
        if in_window and row[3] in CEREMONY_STAGES:
            costs[row[3]].append(milliseconds / 1000)
    for timestamps in spawns.values():
        timestamps.sort()
    return spawns, spawn_count if dispatch_seen else None, costs


def runtime_record(line):
    """(worker key, timestamp, issue, result) from one worker metric, else None."""
    if '"role":"worker"' not in line:
        return None
    try:
        record = json.loads(line)
        timestamp = float(record["ts"])
        issue = str(int(record["issue_number"]))
    except (ValueError, TypeError, KeyError, OverflowError):
        return None
    if not math.isfinite(timestamp):
        return None
    key = str(record.get("worker_id") or f"{issue}@{timestamp}")
    return key, timestamp, issue, str(record.get("result") or "")


def runtime_exits(log_dir, since, until):
    """One exit per dispatched worker; pulse.log misses many worker_exited lines.

    Resumes and model retries write extra records under the same worker_id
    without releasing the slot, so only the latest record counts. A latest
    *_continue or rate_limit_fast record means the worker is still resuming,
    so it stays an open interval.
    """
    latest = {}
    for line in lines(log_dir / "headless-runtime-metrics.jsonl"):
        parsed = runtime_record(line)
        if parsed is None or not since - 21600 <= parsed[1] < until + 21600:
            continue
        if parsed[0] not in latest or parsed[1] >= latest[parsed[0]][1]:
            latest[parsed[0]] = parsed
    return [(timestamp, issue) for _, timestamp, issue, result in latest.values()
            if not (result.endswith("_continue") or result == "rate_limit_fast")]


def ceremony_intervals(log_dir, since, until):
    ceremonies = []
    timing_seen = False
    for end, seconds, row in tsv_rows(log_dir / "pulse-stage-timings.log", 5, 2):
        timing_seen |= since <= end < until
        if row[1].startswith("dispatch_candidate_") and end > since and end - seconds < until:
            ceremonies.append((end - seconds, end))
    return ceremonies, timing_seen
