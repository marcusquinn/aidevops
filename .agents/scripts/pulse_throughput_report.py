#!/usr/bin/env python3
"""Read-only Pulse metrics from current (not rotated) local logs.

Windows are half-open [since, until), in UTC; naive ISO dates mean UTC.
Missing metrics are null in JSON and n/a in text. slot_occupancy adds an open
interval for each spawn without an exit record, so windows ending near now are
not under-counted; slot_occupancy_paired_only omits them. Both are inferred
from logs; slot_occupancy_census is Pulse's own per-round ps count. No
subprocesses, network access or file writes. Use the shell wrapper
(python3 -B) to prevent Python bytecode-cache writes.
"""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path

from pulse_throughput_events import pulse_metrics
from pulse_throughput_logs import CEREMONY_STAGES, ceremony_intervals, dispatch_metrics, iso_time, runtime_exits
from pulse_throughput_metrics import census_metrics, concurrency_metrics, summary, supervisor_metrics
from pulse_throughput_workers import occupancy_metrics


def current_worker_limit(log_dir):
    # Same read-only source as pulse-capacity.sh:get_max_workers_target.
    # Do not invent its fallback of 1 when no configured target is available.
    try:
        value = (log_dir / "pulse-max-workers").read_text(encoding="utf-8").strip()
        return int(value) if value.isascii() and value.isdigit() else None
    except (OSError, ValueError):
        return None


def report(log_dir, since, until, now):
    spawns, spawn_count, costs = dispatch_metrics(log_dir, since, until)
    exits, caps, census, supervisor, pulse_seen, refills = pulse_metrics(log_dir, since, until)
    exits += runtime_exits(log_dir, since, until)
    runtimes, occupancy, paired_only = occupancy_metrics(spawns, exits, (since, until), now)
    ceremonies, timing_seen = ceremony_intervals(log_dir, since, until)
    worker_limit = current_worker_limit(log_dir)
    return {
        "window": {"since": datetime.fromtimestamp(since, timezone.utc).isoformat(),
                   "until": datetime.fromtimestamp(until, timezone.utc).isoformat()},
        "spawns": spawn_count,
        "worker_runtime_minutes": summary(runtimes, spawn_count is not None and pulse_seen),
        "slot_occupancy": {**occupancy, "configured_worker_limit_current": worker_limit},
        "slot_occupancy_paired_only": {**paired_only, "configured_worker_limit_current": worker_limit},
        "slot_occupancy_census": census_metrics(census, since, until),
        "ceremony_seconds": {stage: summary(costs[stage], spawn_count is not None) for stage in CEREMONY_STAGES},
        "ceremony_concurrency": concurrency_metrics(ceremonies, timing_seen, caps, since, until),
        "refill": refills,
        "supervisor": supervisor_metrics(supervisor, pulse_seen, since, until, now),
        "notes": ["Current log files only; rotation can leave partial coverage.",
                  "Exits are pulse.log worker_exited lines plus headless-runtime-metrics worker records.",
                  "Worker pairing is latest earlier same-issue spawn within six hours; duplicate exits are ignored.",
                  "Runtime uses exits in the window; occupancy includes paired intervals crossing window boundaries.",
                  "Open intervals are spawns without a paired exit, ending at the next same-issue spawn, the longest "
                  "paired runtime, the latest host boot, or now; only the latest boot is known.",
                  "Census is Pulse's own ps count of live workers at each Dispatch_capacity round, carried forward "
                  "at most max_age_seconds; it uses the preceding log timestamp and samples only when rounds run.",
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
