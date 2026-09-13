#!/usr/bin/env python3
"""CLI entrypoint for assistant session interval aggregation."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

from session_time_aggregate import aggregate
from session_time_common import DAY_MS, WINDOWS, completed_day_window
from session_time_db import db_paths
from session_time_db_roots import query_observability_roots, query_session_db_roots


def parser():
    result = argparse.ArgumentParser()
    result.add_argument("--repo", action="append", default=[])
    result.add_argument("--all-dirs", action="store_true")
    result.add_argument("--batch", action="store_true")
    result.add_argument("--db-path", default="")
    result.add_argument("--cache-file", default="")
    result.add_argument("--period", choices=tuple(WINDOWS) + ("profile", "all"), default="month")
    result.add_argument("--now-ms", type=int, default=int(time.time() * 1000))
    return result


def collect_sessions(home, explicit, roots, since):
    sessions = {root: [] for root in roots}
    seen = {root: set() for root in roots}
    source_ok = {root: False for root in roots}
    skipped_rows = {root: 0 for root in roots}
    for db_path in db_paths(home, explicit):
        queried, ok, skipped = query_session_db_roots(db_path, roots, since)
        for root in roots:
            skipped_rows[root] += skipped[root]
            source_ok[root] = source_ok[root] or ok
            for row in queried[root]:
                if row["session_id"] not in seen[root]:
                    sessions[root].append(row)
                    seen[root].add(row["session_id"])
    return sessions, source_ok, skipped_rows


def requested_periods(period):
    if period == "profile":
        return ["day", "week", "28d", "year"]
    if period == "all":
        return ["day", "week", "month", "quarter", "year"]
    return [period]


def aggregate_periods(periods, context, completed_days=False):
    result = {}
    for period in periods:
        if completed_days:
            days = WINDOWS.get(period, WINDOWS["month"]) // DAY_MS
            since, end = completed_day_window(context["now"], days)
            semantics = "completed-local-calendar-days"
        else:
            since, end = context["now"] - WINDOWS.get(period, WINDOWS["month"]), context["now"]
            semantics = "rolling-clock-window"
        result[period] = aggregate(context["sessions"], context["obs_rows"], since, end, context["source_ok"])
        result[period]["skipped_malformed_rows"] = context["skipped"]
        result[period]["period_start_ms"] = since
        result[period]["period_end_ms"] = end
        result[period]["period_semantics"] = semantics
    return result


def write_cache(cache_file, payloads):
    if not cache_file:
        return
    path = Path(cache_file)
    if path.is_symlink() or not path.parent.is_dir():
        raise OSError("session-time cache path is not a safe regular-file target")
    current = {}
    if path.is_file():
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            current = loaded
    for root, period_payloads in payloads.items():
        cached_periods = current.get(root, {})
        if not isinstance(cached_periods, dict):
            cached_periods = {}
        cached_periods.update(period_payloads)
        current[root] = cached_periods
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(current, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    args = parser().parse_args()
    if args.all_dirs and args.repo:
        raise SystemExit("--all-dirs cannot be combined with --repo")
    roots = [""] if args.all_dirs else [os.path.abspath(item) for item in (args.repo or ["."])]
    roots = list(dict.fromkeys(roots))
    home = Path.home()
    maximum_since = args.now_ms - WINDOWS["year"] - 2 * DAY_MS
    sessions, session_ok, skipped = collect_sessions(home, args.db_path, roots, maximum_since)
    obs_rows, obs_ok, obs_skipped = query_observability_roots(home, roots, maximum_since, args.now_ms)
    periods = requested_periods(args.period)
    payloads = {}
    for root in roots:
        context = {
            "sessions": sessions[root],
            "obs_rows": obs_rows[root],
            "now": args.now_ms,
            "source_ok": session_ok[root] or obs_ok,
            "skipped": skipped[root] + obs_skipped[root],
        }
        result = aggregate_periods(periods, context, args.period == "profile")
        payloads[root] = result if len(periods) > 1 else result[periods[0]]
    if args.period != "profile":
        cache_payloads = {
            root: result if len(periods) > 1 else {periods[0]: result}
            for root, result in payloads.items()
        }
        write_cache(args.cache_file, cache_payloads)
    payload = payloads if args.batch or len(roots) > 1 else payloads[roots[0]]
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
