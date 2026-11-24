"""Streaming readers for Pulse dispatch and ceremony TSV logs."""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from collections import defaultdict
from datetime import datetime, timezone
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
        if row[3] == "dedup.worker_spawn" and since - 21600 <= timestamp < until:
            spawns[row[1].lstrip("#")].append(timestamp)
            spawn_count += int(in_window)
        if in_window and row[3] in CEREMONY_STAGES:
            costs[row[3]].append(milliseconds / 1000)
    for timestamps in spawns.values():
        timestamps.sort()
    return spawns, spawn_count if dispatch_seen else None, costs


def ceremony_intervals(log_dir, since, until):
    ceremonies = []
    timing_seen = False
    for end, seconds, row in tsv_rows(log_dir / "pulse-stage-timings.log", 5, 2):
        timing_seen |= since <= end < until
        if row[1].startswith("dispatch_candidate_") and end > since and end - seconds < until:
            ceremonies.append((end - seconds, end))
    return ceremonies, timing_seen
