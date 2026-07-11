#!/usr/bin/env python3
"""CLI entrypoint for assistant session interval aggregation."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from session_time_aggregate import aggregate
from session_time_common import WINDOWS
from session_time_db import db_paths, query_observability, query_session_db


def parser():
    result = argparse.ArgumentParser()
    result.add_argument("--repo", default="")
    result.add_argument("--all-dirs", action="store_true")
    result.add_argument("--db-path", default="")
    result.add_argument("--period", choices=tuple(WINDOWS) + ("profile", "all"), default="month")
    result.add_argument("--now-ms", type=int, default=int(time.time() * 1000))
    return result


def collect_sessions(home, explicit, root, since):
    sessions = []
    seen = set()
    source_ok = False
    skipped_rows = 0
    for db_path in db_paths(home, explicit):
        queried, ok, skipped = query_session_db(db_path, root, since)
        skipped_rows += skipped
        source_ok = source_ok or ok
        for row in queried:
            if row["session_id"] not in seen:
                sessions.append(row)
                seen.add(row["session_id"])
    return sessions, source_ok, skipped_rows


def requested_periods(period):
    if period == "profile":
        return ["day", "week", "28d", "year"]
    if period == "all":
        return ["day", "week", "month", "quarter", "year"]
    return [period]


def aggregate_periods(periods, context):
    result = {}
    for period in periods:
        since = context["now"] - WINDOWS.get(period, WINDOWS["month"])
        result[period] = aggregate(context["sessions"], context["obs_rows"], since, context["now"], context["source_ok"])
        result[period]["skipped_malformed_rows"] = context["skipped"]
    return result


def main():
    args = parser().parse_args()
    root = "" if args.all_dirs else os.path.abspath(args.repo or ".")
    home = Path.home()
    maximum_since = args.now_ms - WINDOWS["year"]
    sessions, session_ok, skipped = collect_sessions(home, args.db_path, root, maximum_since)
    obs_rows, obs_ok, obs_skipped = query_observability(home, root, maximum_since, args.now_ms)
    skipped += obs_skipped
    periods = requested_periods(args.period)
    context = {"sessions": sessions, "obs_rows": obs_rows, "now": args.now_ms, "source_ok": session_ok or obs_ok, "skipped": skipped}
    result = aggregate_periods(periods, context)
    payload = result if len(periods) > 1 else result[periods[0]]
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
