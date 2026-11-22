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
from screen_time_linux_activity import COLLECTOR as LINUX_COLLECTOR
from screen_time_macos_apps import macos_app_stats
from screen_time_sources import SAMPLED_PLATFORMS, display_collection, input_collection, record_input_sample, with_evidence

COLLECTION_COMMANDS = ("profile", "query", "date", "earliest", "collector")
DIRECT_COMMANDS = ("apps", "next-date", "history-summary", "history-dates", "revisable-dates", "sample", "input-profile")
# Completed days whose evidence can still grow after a snapshot: display spans
# are written when they end, so a day recorded while the display was on is low.
REVISABLE_DAYS = 3


def parser():
    result = argparse.ArgumentParser()
    result.add_argument("command", choices=COLLECTION_COMMANDS + DIRECT_COMMANDS)
    result.add_argument("--os-type", required=True)
    result.add_argument("--db", default="")
    result.add_argument("--history", default="")
    result.add_argument("--activity-dir", default=os.environ.get("AIDEVOPS_SCREEN_ACTIVITY_DIR", ""))
    result.add_argument("--days", type=int, default=1)
    result.add_argument("--date", default="")
    result.add_argument("--now", type=float, default=float(os.environ.get("AIDEVOPS_SCREEN_TIME_NOW_EPOCH", "0") or 0))
    result.add_argument("--user", default=os.environ.get("AIDEVOPS_SCREEN_TIME_USER", getpass.getuser()))
    return result


def current_epoch(value):
    if value:
        return value
    return dt.datetime.now(dt.timezone.utc).timestamp()


def activity_dir(args):
    if args.activity_dir:
        return Path(args.activity_dir)
    return Path(args.history).parent if args.history else None


def history_collector(args):
    """Linux history rows count only when recorded from input activity.

    Earlier Linux rows came from login-session/lock-state proxies (~24h/day)
    and carry no activity collector, so they must not feed profile periods.
    """
    return LINUX_COLLECTOR if args.os_type == "Linux" else None


def collect(args):
    return display_collection(args.os_type, args.db, args.now, activity_dir(args))


def input_profile(args):
    # No history: the activity log itself keeps 400 days of intervals.
    collection = input_collection(args.os_type, args.now, activity_dir(args))
    print(json.dumps(with_evidence(profile_payload(collection, None, args.now), collection), sort_keys=True))


def accepted_history(args):
    path = Path(args.history) if args.history else None
    return read_history(path, args.now, history_collector(args))


def history_summary(args):
    rows, skipped = accepted_history(args)
    payload = {
        "valid_rows": len(rows),
        "skipped_rows": skipped,
        "earliest": min(rows).isoformat() if rows else None,
        "latest": max(rows).isoformat() if rows else None,
        "total_hours": round(sum(value[0] for value in rows.values()), 1),
    }
    print(json.dumps(payload, sort_keys=True))


def revisable_dates(args):
    """Print ``date hours`` for recorded days a snapshot may still raise."""
    today = local_date(args.now)
    rows = accepted_history(args)[0]
    recent = (today - dt.timedelta(days=offset) for offset in range(REVISABLE_DAYS, 0, -1))
    sys.stdout.write("".join(f"{date.isoformat()} {rows[date][0]}\n" for date in recent if date in rows))


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
        payload = profile_payload(collection, history, args.now, history_collector(args))
        print(json.dumps(with_evidence(payload, collection), sort_keys=True))
    elif args.command == "collector":
        print(collection.get("source", "unknown"))
    elif args.command == "query":
        payload = period_payload(collection, args.now, max(1, args.days) * DAY)
        print("unavailable" if payload["hours"] is None else payload["hours"])
    elif args.command == "date":
        hours = date_hours(collection, args)
        print("unavailable" if hours is None else hours)
    else:
        print_earliest(collection)


def sample(args):
    """Record one human input-activity sample (Linux and macOS)."""
    if args.os_type not in SAMPLED_PLATFORMS:
        summary = {"status": "skipped", "reason": f"no-sampler-needed:{args.os_type}"}
    elif activity_dir(args) is None:
        print("screen-time sample requires --history or --activity-dir", file=sys.stderr)
        return 2
    else:
        summary = record_input_sample(args.os_type, args.now, args.user, activity_dir(args))
    # Scheduled runs stay silent so the per-minute log does not grow.
    if sys.stdout.isatty() or os.environ.get("AIDEVOPS_SCREEN_TIME_DEBUG") == "1":
        print(json.dumps(summary, sort_keys=True))
    return 0


def run_direct_command(args):
    if args.command == "apps":
        print(json.dumps(macos_app_stats(Path(args.db), args.now), sort_keys=True))
    elif args.command == "next-date":
        print((dt.date.fromisoformat(args.date) + dt.timedelta(days=1)).isoformat())
    elif args.command == "history-summary":
        history_summary(args)
    elif args.command == "history-dates":
        print("\n".join(sorted(date.isoformat() for date in accepted_history(args)[0])))
    elif args.command == "revisable-dates":
        revisable_dates(args)
    elif args.command == "input-profile":
        input_profile(args)
    else:
        return sample(args)
    return 0


def main():
    args = parser().parse_args()
    if hasattr(time, "tzset"):
        time.tzset()
    args.now = current_epoch(args.now)
    if args.command in DIRECT_COMMANDS:
        return run_direct_command(args)
    run_collection_command(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
