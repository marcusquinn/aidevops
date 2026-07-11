#!/usr/bin/env python3
"""Deterministic screen-time interval collection and aggregation."""

from __future__ import annotations

import argparse
import datetime as dt
import getpass
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

CORE_DATA_EPOCH = 978307200
DAY = 86400
WINDOWS = {"day": DAY, "week": 7 * DAY, "month": 28 * DAY, "year": 365 * DAY}


def union_intervals(intervals, start, end):
    clipped = sorted((max(start, a), min(end, b)) for a, b in intervals if b > start and a < end)
    merged = []
    for left, right in clipped:
        if right <= left:
            continue
        if merged and left <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], right))
        else:
            merged.append((left, right))
    return merged


def interval_seconds(intervals, start, end):
    return min(end - start, sum(right - left for left, right in union_intervals(intervals, start, end)))


def parse_timestamp(value):
    value = value.strip().replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.timestamp()
    except ValueError:
        return None


def state_intervals(events, start, end, initial=False):
    state = initial
    opened = start if state else None
    intervals = []
    for timestamp, new_state in sorted(events):
        if timestamp < start:
            state = new_state
            opened = start if state else None
            continue
        if timestamp > end:
            break
        if new_state == state:
            continue
        if state and opened is not None:
            intervals.append((opened, timestamp))
        state = new_state
        opened = timestamp if state else None
    if state and opened is not None and opened < end:
        intervals.append((opened, end))
    return union_intervals(intervals, start, end)


def macos_collection(db_path, now):
    if not db_path.exists():
        return {"status": "unavailable", "source": "macos-knowledge-db", "reason": "database-missing", "intervals": []}
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=5) as connection:
            backlit_rows = connection.execute(
                "SELECT ZCREATIONDATE, ZVALUEINTEGER FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/display/isBacklit' ORDER BY ZCREATIONDATE"
            ).fetchall()
            app_rows = connection.execute(
                "SELECT ZSTARTDATE, ZENDDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/app/usage' ORDER BY ZSTARTDATE"
            ).fetchall()
    except (OSError, sqlite3.Error) as exc:
        return {"status": "unavailable", "source": "macos-knowledge-db", "reason": f"database-read-failed:{type(exc).__name__}", "intervals": []}

    backlit = [(float(timestamp) + CORE_DATA_EPOCH, bool(state)) for timestamp, state in backlit_rows if timestamp is not None]
    apps = [
        (float(start) + CORE_DATA_EPOCH, float(end) + CORE_DATA_EPOCH)
        for start, end in app_rows
        if start is not None and end is not None and float(end) > float(start)
    ]
    latest_backlit = max((item[0] for item in backlit), default=None)
    latest_app = max((item[1] for item in apps), default=None)
    earliest = now - WINDOWS["year"]
    backlit_intervals = state_intervals(backlit, earliest, now)
    app_intervals = union_intervals(apps, earliest, now)

    def active_dates(intervals, window_days=28):
        dates = set()
        window_start = now - window_days * DAY
        for left, right in union_intervals(intervals, window_start, now):
            cursor = dt.datetime.fromtimestamp(left, dt.timezone.utc).date()
            final = dt.datetime.fromtimestamp(max(left, right - 1), dt.timezone.utc).date()
            while cursor <= final:
                dates.add(cursor)
                cursor += dt.timedelta(days=1)
        return dates

    backlit_dates = active_dates(backlit_intervals)
    app_dates = active_dates(app_intervals)
    use_backlit = (
        latest_backlit is not None
        and now - latest_backlit <= 3 * DAY
        and not (len(backlit_dates) <= 1 and len(app_dates) >= 2)
    )
    if use_backlit:
        intervals = backlit_intervals
        source = "macos-knowledge-db:/display/isBacklit"
        latest = latest_backlit
        observations = len(backlit)
    elif apps:
        intervals = app_intervals
        source = "macos-knowledge-db:/app/usage-union"
        latest = latest_app
        observations = len(apps)
    elif backlit:
        intervals = backlit_intervals
        source = "macos-knowledge-db:/display/isBacklit-stale"
        latest = latest_backlit
        observations = len(backlit)
    else:
        return {"status": "ok", "source": "macos-knowledge-db:no-observations", "reason": "empty-readable-database", "intervals": [], "observations": 0}
    freshness = max(0.0, (now - latest) / 3600) if latest is not None else None
    status = "stale" if freshness is not None and freshness > 72 else "ok"
    return {
        "status": status,
        "source": source,
        "reason": "source-observations",
        "intervals": intervals,
        "observations": observations,
        "latest_epoch": latest,
        "freshness_hours": round(freshness, 1) if freshness is not None else None,
    }


def macos_app_stats(db_path, now):
    if not db_path.exists():
        return []
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=5) as connection:
            rows = connection.execute(
                "SELECT ZVALUESTRING, ZSTARTDATE, ZENDDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/app/usage' AND ZVALUESTRING IS NOT NULL"
            ).fetchall()
    except sqlite3.Error:
        return []
    intervals = [
        (str(bundle), float(start) + CORE_DATA_EPOCH, float(end) + CORE_DATA_EPOCH)
        for bundle, start, end in rows
        if start is not None and end is not None and float(end) > float(start)
    ]
    totals = {}
    for name, seconds in (("today", DAY), ("week", 7 * DAY), ("month", 28 * DAY)):
        window_start = now - seconds
        relevant = [(bundle, max(start, window_start), min(end, now), start) for bundle, start, end in intervals if end > window_start and start < now]
        boundaries = sorted({value for _, left, right, _ in relevant for value in (left, right)})
        per_app = {}
        for left, right in zip(boundaries, boundaries[1:]):
            active = [item for item in relevant if item[1] < right and item[2] > left]
            if not active:
                continue
            # Knowledge DB foreground records can overlap or repeat. Attribute a
            # segment once to the most recently started active record.
            bundle = max(active, key=lambda item: item[3])[0]
            per_app[bundle] = per_app.get(bundle, 0) + right - left
        totals[name] = per_app
    month_total = sum(totals.get("month", {}).values())
    result = []
    for bundle, month_seconds in sorted(totals.get("month", {}).items(), key=lambda item: (-item[1], item[0]))[:10]:
        row = {"bundle": bundle}
        for name in ("today", "week", "month"):
            denominator = sum(totals.get(name, {}).values())
            row[f"{name}_pct"] = round(totals.get(name, {}).get(bundle, 0) / denominator * 100) if denominator else 0
        row["month_seconds"] = round(month_seconds)
        result.append(row)
    return result if month_total else []


SESSION_NEW = re.compile(r"New session ([A-Za-z0-9_.-]+) of user ([^ .]+)", re.I)
SESSION_END = re.compile(r"(?:Removed session|Session) ([A-Za-z0-9_.-]+)(?: logged out)?", re.I)
SESSION_ID = re.compile(r"Session ([A-Za-z0-9_.-]+)", re.I)


def journal_lines(now):
    fixture = os.environ.get("AIDEVOPS_LOGIND_FIXTURE")
    if fixture:
        try:
            return Path(fixture).read_text(encoding="utf-8").splitlines(), None
        except OSError as exc:
            return [], f"fixture-read-failed:{type(exc).__name__}"
    try:
        result = subprocess.run(
            ["journalctl", "--since", "366 days ago", "-u", "systemd-logind.service", "--no-pager", "-o", "short-iso"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [], f"journal-read-failed:{type(exc).__name__}"
    if result.returncode != 0:
        return [], f"journal-read-failed:exit-{result.returncode}"
    return result.stdout.splitlines(), None


def wtmp_collection(now, user, journal_reason):
    fixture = os.environ.get("AIDEVOPS_LAST_FIXTURE")
    if fixture:
        try:
            lines = Path(fixture).read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            return {"status": "unavailable", "source": "linux-wtmp", "reason": f"fixture-read-failed:{type(exc).__name__}", "intervals": []}
    else:
        try:
            result = subprocess.run(
                ["last", "-F", "-s", "-365days", user], check=False, capture_output=True, text=True, timeout=30
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"status": "unavailable", "source": "linux-logind+wtmp", "reason": f"{journal_reason};wtmp-read-failed:{type(exc).__name__}", "intervals": []}
        if result.returncode != 0:
            return {"status": "unavailable", "source": "linux-logind+wtmp", "reason": f"{journal_reason};wtmp-read-failed:exit-{result.returncode}", "intervals": []}
        lines = result.stdout.splitlines()
    intervals = []
    for line in lines:
        structured = re.match(r"^([0-9]+)\|([0-9]+)$", line.strip())
        if structured:
            intervals.append((float(structured.group(1)), float(structured.group(2))))
            continue
        dates = re.findall(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2}\s+[0-9]{1,2} [0-9:]{8} [0-9]{4}", line)
        if len(dates) >= 2:
            try:
                left = dt.datetime.strptime(dates[0], "%a %b %d %H:%M:%S %Y").replace(tzinfo=dt.timezone.utc).timestamp()
                right = dt.datetime.strptime(dates[1], "%a %b %d %H:%M:%S %Y").replace(tzinfo=dt.timezone.utc).timestamp()
                if right > left:
                    intervals.append((left, right))
            except ValueError:
                continue
    if not intervals:
        return {"status": "unavailable", "source": "linux-logind+wtmp", "reason": f"{journal_reason};no-parseable-wtmp-sessions", "intervals": []}
    latest = max(right for _, right in intervals)
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "linux-wtmp:login-session-proxy",
        "reason": f"logind-unavailable:{journal_reason}",
        "intervals": union_intervals(intervals, now - WINDOWS["year"], now),
        "observations": len(intervals),
        "latest_epoch": latest,
        "freshness_hours": round(freshness, 1),
    }


def linux_collection(now, user):
    lines, error = journal_lines(now)
    if error:
        return wtmp_collection(now, user, error)
    sessions = {}
    lid_open = True
    active = False
    opened = None
    intervals = []
    observations = 0
    latest = None
    start = now - WINDOWS["year"]

    def is_active():
        return lid_open and any(not locked for locked in sessions.values())

    for line in lines:
        first = line.split(None, 1)
        if len(first) != 2:
            continue
        timestamp = parse_timestamp(first[0])
        if timestamp is None or timestamp > now:
            continue
        message = first[1]
        before = is_active()
        recognized = False
        match = SESSION_NEW.search(message)
        if match and match.group(2) == user:
            sessions[match.group(1).rstrip(".")] = False
            recognized = True
        else:
            lowered = message.lower()
            match = SESSION_ID.search(message) if "locked" in lowered else None
            session_id = match.group(1).rstrip(".") if match else ""
            if session_id in sessions:
                sessions[session_id] = "unlocked" not in lowered
                recognized = True
            elif "Lid closed" in message:
                lid_open = False
                recognized = True
            elif "Lid opened" in message:
                lid_open = True
                recognized = True
            else:
                match = SESSION_END.search(message)
                session_id = match.group(1).rstrip(".") if match else ""
                if session_id in sessions:
                    sessions.pop(session_id, None)
                    recognized = True
        if not recognized:
            continue
        if os.environ.get("AIDEVOPS_SCREEN_TIME_DEBUG") == "1":
            print(
                f"screen-time event ts={timestamp} before={before} after={is_active()} sessions={sessions} lid_open={lid_open} message={message}",
                file=sys.stderr,
            )
        observations += 1
        latest = timestamp if latest is None else max(latest, timestamp)
        after = is_active()
        if before == after:
            continue
        if before and opened is not None:
            intervals.append((opened, timestamp))
        opened = timestamp if after else None
        active = after
    if active and opened is not None:
        intervals.append((opened, now))
    intervals = union_intervals(intervals, start, now)
    if observations == 0:
        return {"status": "ok", "source": "linux-systemd-logind", "reason": "no-user-session-observations", "intervals": [], "observations": 0}
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "linux-systemd-logind:session-lid-lock-state",
        "reason": "source-observations",
        "intervals": intervals,
        "observations": observations,
        "latest_epoch": latest,
        "freshness_hours": round(freshness, 1),
    }


def coverage(collection, start, end):
    timestamps = []
    for left, right in collection.get("intervals", []):
        if right > start and left < end:
            timestamps.extend((max(left, start), min(right, end)))
    latest = collection.get("latest_epoch")
    if latest is not None and latest >= start:
        timestamps.append(min(latest, end))
    if not timestamps:
        return 0.0, 0.0
    observed_start = max(start, min(timestamps))
    observed_end = min(end, max(timestamps))
    days = min((end - start) / DAY, max(1.0, (observed_end - observed_start) / DAY + 1.0))
    return round(days, 1), round(days / ((end - start) / DAY) * 100, 1)


def period_payload(collection, now, seconds):
    start = now - seconds
    observed_days, coverage_pct = coverage(collection, start, now)
    status = collection.get("status", "unavailable")
    hours = None if status == "unavailable" else round(interval_seconds(collection.get("intervals", []), start, now) / 3600, 1)
    return {
        "hours": hours,
        "status": status,
        "source": collection.get("source", "unknown"),
        "reason": collection.get("reason", "unknown"),
        "coverage_days": observed_days,
        "coverage_pct": coverage_pct,
        "freshness_hours": collection.get("freshness_hours"),
        "observations": collection.get("observations", 0),
        "estimated": False,
    }


def read_history(history_path, now):
    rows = {}
    if not history_path or not history_path.exists():
        return rows
    try:
        for line in history_path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            date = dt.date.fromisoformat(str(row.get("date")))
            hours = max(0.0, min(24.0, float(row.get("screen_hours"))))
            rows[date] = (hours, row)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return {}
    return rows


def history_period(rows, now, days):
    end_date = dt.datetime.fromtimestamp(now, dt.timezone.utc).date()
    start_date = end_date - dt.timedelta(days=days)
    selected = [(date, value) for date, value in rows.items() if start_date <= date < end_date]
    if not selected:
        return None
    dates = [item[0] for item in selected]
    total = round(sum(item[1][0] for item in selected), 1)
    span = max(1, (max(dates) - min(dates)).days + 1)
    latest_age = (end_date - max(dates)).days
    return {
        "hours": min(days * 24.0, total),
        "status": "stale" if latest_age > 2 else "ok",
        "source": "screen-time-history:daily-observations",
        "reason": "live-source-unavailable",
        "coverage_days": len(selected),
        "calendar_span_days": span,
        "coverage_pct": round(len(selected) / days * 100, 1),
        "freshness_hours": latest_age * 24,
        "observations": len(selected),
        "estimated": False,
    }


def profile_payload(collection, history_path, now):
    periods = {name: period_payload(collection, now, seconds) for name, seconds in WINDOWS.items()}
    history = read_history(history_path, now)
    for name, days in (("day", 1), ("week", 7), ("month", 28)):
        if periods[name]["status"] == "unavailable":
            fallback = history_period(history, now, days)
            if fallback:
                periods[name] = fallback
    year_history = history_period(history, now, 365)
    if year_history:
        span = year_history.get("calendar_span_days", 0)
        observed = year_history.get("coverage_days", 0)
        if span >= 330:
            periods["year"] = year_history
        elif span > 0 and observed > 0:
            estimate = min(8760.0, year_history["hours"] / span * 365)
            periods["year"] = dict(year_history, hours=round(estimate, 1), estimated=True, reason="calendar-span-extrapolation")
    elif periods["year"]["status"] != "unavailable" and periods["month"]["coverage_days"] > 0:
        base = periods["month"]
        estimate = min(8760.0, (base["hours"] or 0) / base["coverage_days"] * 365)
        periods["year"] = dict(base, hours=round(estimate, 1), estimated=True, reason="observed-calendar-coverage-extrapolation")
    return {
        "today_hours": periods["day"]["hours"],
        "week_hours": periods["week"]["hours"],
        "month_hours": periods["month"]["hours"],
        "year_hours": periods["year"]["hours"],
        "month_note": periods["month"]["source"],
        "periods": periods,
        "collection_status": collection.get("status", "unavailable"),
    }


def collect(args):
    if args.os_type == "Darwin":
        return macos_collection(Path(args.db), args.now)
    if args.os_type == "Linux":
        return linux_collection(args.now, args.user)
    return {"status": "unavailable", "source": "unsupported-platform", "reason": args.os_type, "intervals": []}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("profile", "query", "date", "earliest", "apps"))
    parser.add_argument("--os-type", required=True)
    parser.add_argument("--db", default="")
    parser.add_argument("--history", default="")
    parser.add_argument("--days", type=int, default=1)
    parser.add_argument("--date", default="")
    parser.add_argument("--now", type=float, default=float(os.environ.get("AIDEVOPS_SCREEN_TIME_NOW_EPOCH", "0") or 0))
    parser.add_argument("--user", default=os.environ.get("AIDEVOPS_SCREEN_TIME_USER", getpass.getuser()))
    args = parser.parse_args()
    if not args.now:
        args.now = dt.datetime.now(dt.timezone.utc).timestamp()
    if args.command == "apps":
        print(json.dumps(macos_app_stats(Path(args.db), args.now), sort_keys=True))
        return 0
    collection = collect(args)
    if args.command == "profile":
        payload = profile_payload(collection, Path(args.history) if args.history else None, args.now)
        print(json.dumps(payload, sort_keys=True))
    elif args.command == "query":
        payload = period_payload(collection, args.now, max(1, args.days) * DAY)
        print("unavailable" if payload["hours"] is None else payload["hours"])
    elif args.command == "date":
        target = dt.date.fromisoformat(args.date)
        start = dt.datetime.combine(target, dt.time.min, tzinfo=dt.timezone.utc).timestamp()
        hours = None if collection.get("status") == "unavailable" else round(interval_seconds(collection.get("intervals", []), start, start + DAY) / 3600, 1)
        print("unavailable" if hours is None else hours)
    else:
        starts = [left for left, _ in collection.get("intervals", [])]
        print(dt.datetime.fromtimestamp(min(starts), dt.timezone.utc).date().isoformat() if starts else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
