#!/usr/bin/env python3
"""CLI entrypoint for deterministic screen-time interval aggregation."""

from __future__ import annotations

import argparse
import datetime as dt
import getpass
import json
import os
import sys
import time
from pathlib import Path

from screen_time_history import period_payload, profile_payload, read_history
from screen_time_interval_common import DAY, interval_seconds, local_date, local_day_bounds
from screen_time_linux import linux_collection
from screen_time_macos import macos_collection
from screen_time_macos_apps import macos_app_stats
from screen_time_macos_pmset import pmset_collection


def parser():
    result = argparse.ArgumentParser()
    result.add_argument("command", choices=("profile", "query", "date", "earliest", "apps", "next-date", "history-summary"))
    result.add_argument("--os-type", required=True)
    result.add_argument("--db", default="")
    result.add_argument("--history", default="")
    result.add_argument("--days", type=int, default=1)
    result.add_argument("--date", default="")
    result.add_argument("--now", type=float, default=float(os.environ.get("AIDEVOPS_SCREEN_TIME_NOW_EPOCH", "0") or 0))
    result.add_argument("--user", default=os.environ.get("AIDEVOPS_SCREEN_TIME_USER", getpass.getuser()))
    return result


def current_epoch(value):
    if value:
        return value
    return dt.datetime.now(dt.timezone.utc).timestamp()


def collect(args):
    if args.os_type == "Darwin":
        collection = macos_collection(Path(args.db), args.now)
        return pmset_collection(args.now) if collection.get("status") == "unavailable" else collection
    if args.os_type == "Linux":
        return linux_collection(args.now, args.user)
    return {"status": "unavailable", "source": "unsupported-platform", "reason": args.os_type, "intervals": []}


def history_summary(args):
    path = Path(args.history) if args.history else None
    rows, skipped = read_history(path, args.now)
    payload = {
        "valid_rows": len(rows),
        "skipped_rows": skipped,
        "earliest": min(rows).isoformat() if rows else None,
        "latest": max(rows).isoformat() if rows else None,
        "total_hours": round(sum(value[0] for value in rows.values()), 1),
    }
    print(json.dumps(payload, sort_keys=True))


def date_hours(collection, args):
    try:
        target = dt.date.fromisoformat(args.date)
    except ValueError:
        return None
    start, end = local_day_bounds(target)
    if start is None or end is None or collection.get("status") == "unavailable":
        return None
    observations = collection.get("observation_epochs", [])
    intervals = collection.get("intervals", [])
    explicit_event = any(start <= timestamp < end for timestamp in observations)
    interval_overlap = any(right > start and left < end for left, right in intervals)
    coverage_end = collection.get("coverage_end_epoch")
    within_coverage = coverage_end is not None and start <= coverage_end
    if not within_coverage or not (explicit_event or interval_overlap):
        return None
    return round(min(24 * 3600, interval_seconds(intervals, start, end)) / 3600, 1)


def print_earliest(collection):
    starts = [left for left, _ in collection.get("intervals", [])]
    earliest = collection.get("earliest_epoch")
    if earliest is None and starts:
        earliest = min(starts)
    date = local_date(earliest) if earliest is not None else None
    print(date.isoformat() if date is not None else "")


def run_collection_command(args):
    collection = collect(args)
    if args.command == "profile":
        history = Path(args.history) if args.history else None
        print(json.dumps(profile_payload(collection, history, args.now), sort_keys=True))
    elif args.command == "query":
        payload = period_payload(collection, args.now, max(1, args.days) * DAY)
        print("unavailable" if payload["hours"] is None else payload["hours"])
    elif args.command == "date":
        hours = date_hours(collection, args)
        print("unavailable" if hours is None else hours)
    else:
        print_earliest(collection)


def run_direct_command(args):
    if args.command == "apps":
        print(json.dumps(macos_app_stats(Path(args.db), args.now), sort_keys=True))
        return True
    if args.command == "next-date":
        print((dt.date.fromisoformat(args.date) + dt.timedelta(days=1)).isoformat())
        return True
    if args.command == "history-summary":
        history_summary(args)
        return True
    return False


def main():
    args = parser().parse_args()
    if hasattr(time, "tzset"):
        time.tzset()
    args.now = current_epoch(args.now)
    if not run_direct_command(args):
        run_collection_command(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
