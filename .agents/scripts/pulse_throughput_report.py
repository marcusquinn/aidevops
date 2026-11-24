#!/usr/bin/env python3
"""Read-only Pulse metrics from current (not rotated) local logs.

Windows are half-open [since, until), in UTC; naive ISO dates mean UTC.
Missing metrics are null in JSON and n/a in text. Occupancy is paired-only,
not a census of live workers. No subprocesses, network access or file writes.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import statistics


CEREMONY_STAGES = (
    "dedup.ceremony_total", "dedup.worker_launch_total", "dedup.dedup_check",
    "dedup.precreate_worktree", "dedup.claim_consensus",
)
ISO_PATTERN = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"
ISO_RE = re.compile(ISO_PATTERN)
FIELD_RE = re.compile(r"\b([a-z_]+)=([^\s,)]+)")


def iso_time(value):
    """Parse ISO timestamps, rejecting invalid and non-finite values."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).timestamp()


def lines(path):
    """Stream available logs; absence/rotation or unreadability is non-fatal."""
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            yield from stream
    except OSError:
        return


def summary(values, available=True):
    if not values:
        return {"count": 0 if available else None, "median": None, "p90": None}
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(ordered),
            "p90": ordered[max(0, math.ceil(len(ordered) * 0.9) - 1)]}


def sample_intervals(intervals, since, until, step):
    """Sweep endpoints once instead of testing every interval at each sample."""
    starts = sorted(start for start, _ in intervals)
    ends = sorted(end for _, end in intervals)
    for index in range(math.ceil((until - since) / step)):
        point = since + index * step
        yield bisect_right(starts, point) - bisect_right(ends, point)


def current_worker_limit(log_dir):
    # Same read-only source as pulse-capacity.sh:get_max_workers_target.
    # Do not invent its fallback of 1 when no configured target is available.
    try:
        value = (log_dir / "pulse-max-workers").read_text(encoding="utf-8").strip()
        return int(value) if value.isascii() and value.isdigit() else None
    except (OSError, ValueError):
        return None


def dispatch_metrics(log_dir, since, until):
    spawns = defaultdict(list)
    spawn_count = 0
    dispatch_seen = False
    costs = defaultdict(list)
    for line in lines(log_dir / "dispatch-stages.tsv"):
        row = line.rstrip("\n").split("\t")
        if len(row) < 6:
            continue
        try:
            timestamp = iso_time(row[0])
            milliseconds = float(row[4])
        except (ValueError, OverflowError):
            continue
        in_window = since <= timestamp < until
        dispatch_seen |= in_window
        if row[5] != "complete":
            continue
        if row[3] == "dedup.worker_spawn" and since - 21600 <= timestamp < until:
            spawns[row[1].lstrip("#")].append(timestamp)
            spawn_count += int(in_window)
        if in_window and row[3] in CEREMONY_STAGES and math.isfinite(milliseconds) and milliseconds >= 0:
            costs[row[3]].append(milliseconds / 1000)
    for timestamps in spawns.values():
        timestamps.sort()
    return spawns, spawn_count if dispatch_seen else None, costs


def pulse_records(log_dir):
    """Stream timestamped events, retaining only one timestamp of context."""
    context_timestamp = None
    for line in lines(log_dir / "pulse.log"):
        fields = dict(FIELD_RE.findall(line))
        success = "LLM supervisor completed successfully" in line
        try:
            match = ISO_RE.search(line)
            timestamp = (float(fields["epoch"]) if success else
                         iso_time(fields["ts"]) if "ts" in fields else
                         iso_time(match.group()) if match else None)
        except (ValueError, OverflowError, KeyError):
            continue
        # Dispatch engine round headers lack their own timestamp. Associate
        # only cap observations with the preceding timestamped log record.
        if timestamp is None and "max_parallel" in fields:
            timestamp = context_timestamp
        if timestamp is None or not math.isfinite(timestamp):
            continue
        context_timestamp = timestamp
        yield timestamp, fields, line, success


def positive_cap(fields):
    try:
        value = int(fields.get("max_parallel", ""))
        return value if value > 0 else None
    except ValueError:
        return None


def pulse_metrics(log_dir, since, until):
    refills = Counter()
    supervisor = set()
    pulse_seen = False
    cap_observations = []
    exits = []
    for timestamp, fields, line, success in pulse_records(log_dir):
        in_window = since <= timestamp < until
        pulse_seen |= in_window
        if success and timestamp < until:
            supervisor.add(timestamp)
        if in_window and "[pulse-event-refill]" in line:
            action = fields.get("action", "unknown")
            refills[(fields.get("source", "unknown"), action, fields.get("reason", ""))] += 1
        cap = positive_cap(fields)
        if timestamp < until and cap is not None:
            cap_observations.append((timestamp, cap))
        # Keep exits after until for intervals crossing the right boundary.
        if "[lifecycle] worker_exited" in line and since <= timestamp < until + 21600:
            exits.append((timestamp, fields.get("issue")))
    refill_report = {
        "trigger_recorded": sum(count for (_, action, _), count in refills.items()
                                if action == "trigger_recorded") if pulse_seen else None,
        "outcomes_by_source": [
            {"source": source, "action": action, "reason": reason or None, "count": count}
            for (source, action, reason), count in sorted(refills.items())] if pulse_seen else None,
    }
    return exits, cap_observations, supervisor, pulse_seen, refill_report


def pair_workers(spawns, exits, until):
    intervals = []
    paired = set()
    runtimes = []
    for timestamp, issue in sorted(exits):
        candidates = spawns.get(issue, [])
        index = bisect_left(candidates, timestamp) - 1
        if index < 0:
            continue
        start = candidates[index]
        key = (issue, start)
        if timestamp - start > 21600 or key in paired:
            continue
        paired.add(key)
        if timestamp < until:
            runtimes.append((timestamp - start) / 60)
        if start < until:
            intervals.append((start, timestamp))
    return intervals, runtimes


def ceremony_intervals(log_dir, since, until):
    ceremonies = []
    timing_seen = False
    for line in lines(log_dir / "pulse-stage-timings.log"):
        row = line.rstrip("\n").split("\t")
        if len(row) < 5:
            continue
        try:
            end = iso_time(row[0])
            seconds = float(row[2])
        except (ValueError, OverflowError):
            continue
        timing_seen |= since <= end < until
        if not math.isfinite(seconds) or seconds < 0:
            continue
        if row[1].startswith("dispatch_candidate_") and end > since and end - seconds < until:
            ceremonies.append((end - seconds, end))
    return ceremonies, timing_seen


def concurrency_metrics(ceremonies, timing_seen, cap_observations, since, until):
    concurrency = list(sample_intervals(ceremonies, since, until, 10)) if timing_seen or ceremonies else []
    running = [value for value in concurrency if value > 0]
    caps = {cap for _, cap in cap_observations}
    cap = next(iter(caps)) if len(caps) == 1 else None
    cap_observations.sort()
    cap_times = [timestamp for timestamp, _ in cap_observations]
    capped_samples = []
    for index, value in enumerate(concurrency):
        observation = bisect_right(cap_times, since + index * 10) - 1
        if observation >= 0:
            capped_samples.append(value >= cap_observations[observation][1])
    return {
        "sample_seconds": 10,
        "idle_share": concurrency.count(0) / len(concurrency) if concurrency else None,
        "mean_while_running": statistics.mean(running) if running else None,
        "observed_cap": cap,
        "observed_caps": sorted(caps) if caps else None,
        "cap_sample_coverage_share": len(capped_samples) / len(concurrency) if concurrency else None,
        "share_at_cap": statistics.mean(capped_samples) if capped_samples else None,
    }


def supervisor_metrics(supervisor, pulse_seen, since, until, now):
    successes = sorted(value for value in supervisor if since <= value < until)
    gaps = [(right - left) / 3600 for left, right in zip(successes, successes[1:])]
    return {
        "count": len(successes) if pulse_seen or successes else None,
        "gap_median_hours": statistics.median(gaps) if gaps else None,
        "gap_max_hours": max(gaps) if gaps else None,
        "hours_since_last_success": (now - max(supervisor)) / 3600 if supervisor else None,
    }


def report(log_dir, since, until, now):
    spawns, spawn_count, costs = dispatch_metrics(log_dir, since, until)
    exits, caps, supervisor, pulse_seen, refills = pulse_metrics(log_dir, since, until)
    intervals, runtimes = pair_workers(spawns, exits, until)
    ceremonies, timing_seen = ceremony_intervals(log_dir, since, until)
    occupancy = list(sample_intervals(intervals, since, until, 300)) if intervals else []
    return {
        "window": {"since": datetime.fromtimestamp(since, timezone.utc).isoformat(),
                   "until": datetime.fromtimestamp(until, timezone.utc).isoformat()},
        "spawns": spawn_count,
        "worker_runtime_minutes": summary(runtimes, spawn_count is not None and pulse_seen),
        "slot_occupancy_paired_only": {
            "sample_seconds": 300, "mean": statistics.mean(occupancy) if occupancy else None,
            "max": max(occupancy) if occupancy else None,
            "configured_worker_limit_current": current_worker_limit(log_dir)},
        "ceremony_seconds": {stage: summary(costs[stage], spawn_count is not None) for stage in CEREMONY_STAGES},
        "ceremony_concurrency": concurrency_metrics(ceremonies, timing_seen, caps, since, until),
        "refill": refills,
        "supervisor": supervisor_metrics(supervisor, pulse_seen, since, until, now),
        "notes": ["Current log files only; rotation can leave partial coverage.",
                  "Worker pairing is latest earlier same-issue spawn within six hours; duplicate exits are ignored.",
                  "Runtime uses exits in the window; occupancy includes paired intervals crossing window boundaries.",
                  "p90 uses nearest rank; at-cap share uses samples with a preceding observed round cap (at or above cap).",
                  "Untimestamped round caps use the preceding log timestamp; caps carry forward and may change during the window.",
                  "Missing refill sources are unknown; configured worker limit is current, not historical."],
    }


def print_text(value, prefix=""):
    if isinstance(value, dict):
        for key, item in value.items():
            print_text(item, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, list):
        print(f"{prefix}: {json.dumps(value)}")
    else:
        formatted = "n/a" if value is None else f"{value:.3f}" if isinstance(value, float) else value
        print(f"{prefix}: {formatted}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", help="ISO window start (default: until minus 24 hours)")
    parser.add_argument("--until", help="ISO exclusive window end (default: now)")
    parser.add_argument("--json", action="store_true", help="Print one JSON object; unavailable values are null")
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    try:
        until = iso_time(args.until) if args.until else now.timestamp()
        since = iso_time(args.since) if args.since else until - timedelta(days=1).total_seconds()
        if since >= until:
            raise ValueError("since must be earlier than until")
    except (ValueError, OverflowError) as error:
        parser.error(str(error))
    log_dir = Path(os.environ.get("AIDEVOPS_LOG_DIR", str(Path.home() / ".aidevops/logs")))
    result = report(log_dir, since, until, now.timestamp())
    if args.json:
        print(json.dumps(result, allow_nan=False))
    else:
        print_text(result)


if __name__ == "__main__":
    main()
