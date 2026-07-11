#!/usr/bin/env python3
"""Deterministic screen-time interval collection and aggregation."""

from __future__ import annotations

import argparse
import datetime as dt
import getpass
import heapq
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

CORE_DATA_EPOCH = 978307200
DAY = 86400
WINDOWS = {"day": DAY, "week": 7 * DAY, "month": 28 * DAY, "year": 365 * DAY}


def local_date(timestamp):
    return dt.datetime.fromtimestamp(timestamp).date()


def local_midnight_epoch(date):
    # Naive datetime.timestamp intentionally uses the host TZ database, including
    # the offset applicable on this date rather than today's fixed UTC offset.
    return dt.datetime.combine(date, dt.time.min).timestamp()


def local_day_bounds(date):
    return local_midnight_epoch(date), local_midnight_epoch(date + dt.timedelta(days=1))


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
            cursor = local_date(left)
            final = local_date(max(left, right - 1))
            while cursor <= final:
                dates.add(cursor)
                cursor += dt.timedelta(days=1)
        return dates

    backlit_dates = active_dates(backlit_intervals)
    app_dates = active_dates(app_intervals)
    backlit_seconds = interval_seconds(backlit_intervals, now - 28 * DAY, now)
    app_seconds = interval_seconds(app_intervals, now - 28 * DAY, now)
    app_materially_richer = (
        len(app_dates) > len(backlit_dates)
        and (
            len(app_dates) >= max(len(backlit_dates) + 2, len(backlit_dates) * 2)
            or app_seconds > max(3600, backlit_seconds * 1.5)
        )
    )
    use_backlit = (
        latest_backlit is not None
        and now - latest_backlit <= 3 * DAY
        and not app_materially_richer
    )
    if use_backlit:
        intervals = backlit_intervals
        source = "macos-knowledge-db:/display/isBacklit"
        latest = latest_backlit
        observations = len(backlit)
        observation_epochs = [timestamp for timestamp, _ in backlit]
        coverage_start = min(observation_epochs)
        coverage_end = max(observation_epochs)
    elif apps:
        intervals = app_intervals
        source = "macos-knowledge-db:/app/usage-union"
        latest = latest_app
        observations = len(apps)
        observation_epochs = []
        coverage_start = min(start for start, _ in apps)
        coverage_end = max(end for _, end in apps)
    elif backlit:
        intervals = backlit_intervals
        source = "macos-knowledge-db:/display/isBacklit-stale"
        latest = latest_backlit
        observations = len(backlit)
        observation_epochs = [timestamp for timestamp, _ in backlit]
        coverage_start = min(observation_epochs)
        coverage_end = max(observation_epochs)
    else:
        return {"status": "unavailable", "source": "macos-knowledge-db:no-observations", "reason": "empty-readable-database", "intervals": [], "observations": 0}
    freshness = max(0.0, (now - latest) / 3600) if latest is not None else None
    status = "stale" if freshness is not None and freshness > 72 else "ok"
    return {
        "status": status,
        "source": source,
        "reason": "source-observations",
        "intervals": intervals,
        "observations": observations,
        "latest_epoch": latest,
        "earliest_epoch": min((item[0] for item in (backlit if use_backlit or not apps else apps)), default=latest),
        "freshness_hours": round(freshness, 1) if freshness is not None else None,
        "observation_epochs": observation_epochs,
        "coverage_start_epoch": coverage_start,
        "coverage_end_epoch": coverage_end,
    }


def macos_app_stats(db_path, now):
    if not db_path.exists():
        return []
    try:
        started_at = time.perf_counter()
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=5) as connection:
            cutoff_cd = now - 28 * DAY - CORE_DATA_EPOCH
            now_cd = now - CORE_DATA_EPOCH
            rows = connection.execute(
                "SELECT ZVALUESTRING, ZSTARTDATE, ZENDDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/app/usage' AND ZVALUESTRING IS NOT NULL "
                "AND ZENDDATE > ? AND ZSTARTDATE < ? ORDER BY ZSTARTDATE",
                (cutoff_cd, now_cd),
            ).fetchall()
    except sqlite3.Error:
        return []
    month_start = now - 28 * DAY
    intervals = [
        (str(bundle), max(month_start, float(start) + CORE_DATA_EPOCH), min(now, float(end) + CORE_DATA_EPOCH), float(start) + CORE_DATA_EPOCH)
        for bundle, start, end in rows
        if start is not None and end is not None and float(end) > float(start) and float(end) + CORE_DATA_EPOCH > month_start and float(start) + CORE_DATA_EPOCH < now
    ]
    starts = {}
    ends = {}
    boundaries = {month_start, now}
    for interval_id, (bundle, left, right, original_start) in enumerate(intervals):
        starts.setdefault(left, []).append((interval_id, bundle, original_start))
        ends.setdefault(right, []).append(interval_id)
        boundaries.update((left, right))
    ordered = sorted(boundaries)
    active = set()
    latest_start_heap = []
    totals = {name: {} for name in ("today", "week", "month")}
    window_starts = {"today": now - DAY, "week": now - 7 * DAY, "month": month_start}
    attributed_segments = 0
    max_active = 0
    for left, right in zip(ordered, ordered[1:]):
        for interval_id in ends.get(left, []):
            active.discard(interval_id)
        for interval_id, bundle, original_start in starts.get(left, []):
            active.add(interval_id)
            heapq.heappush(latest_start_heap, (-original_start, -interval_id, interval_id, bundle))
        while latest_start_heap and latest_start_heap[0][2] not in active:
            heapq.heappop(latest_start_heap)
        max_active = max(max_active, len(active))
        if not latest_start_heap or right <= left:
            continue
        bundle = latest_start_heap[0][3]
        attributed_segments += 1
        for name, window_start in window_starts.items():
            overlap = right - max(left, window_start)
            if overlap > 0:
                totals[name][bundle] = totals[name].get(bundle, 0) + overlap
    month_total = sum(totals.get("month", {}).values())
    result = []
    for bundle, month_seconds in sorted(totals.get("month", {}).items(), key=lambda item: (-item[1], item[0]))[:10]:
        row = {"bundle": bundle}
        for name in ("today", "week", "month"):
            denominator = sum(totals.get(name, {}).values())
            row[f"{name}_pct"] = round(totals.get(name, {}).get(bundle, 0) / denominator * 100) if denominator else 0
        row["month_seconds"] = round(month_seconds)
        result.append(row)
    instrument_file = os.environ.get("AIDEVOPS_APP_STATS_INSTRUMENT_FILE")
    if instrument_file:
        instrumentation = {
            "rows_selected": len(rows),
            "valid_intervals": len(intervals),
            "boundaries": len(ordered),
            "attributed_segments": attributed_segments,
            "max_active": max_active,
            "elapsed_ms": round((time.perf_counter() - started_at) * 1000, 3),
        }
        Path(instrument_file).write_text(json.dumps(instrumentation, sort_keys=True) + "\n", encoding="utf-8")
    return result if month_total else []


SESSION_NEW = re.compile(r"New session ([A-Za-z0-9_.-]+) of user ([^ .]+)", re.I)
SESSION_END = re.compile(r"(?:Removed session|Session) ([A-Za-z0-9_.-]+)(?: logged out)?", re.I)
SESSION_ID = re.compile(r"Session ([A-Za-z0-9_.-]+)", re.I)


def run_trusted_command(executable_name, arguments):
    executable = shutil.which(executable_name)
    if not executable or not os.path.isabs(executable):
        return None, "executable-not-found"
    try:
        # The executable is resolved to an absolute path and callers supply a
        # fixed argv shape; no command text reaches a shell.
        result = subprocess.run(  # nosec B603
            [executable, *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"{type(exc).__name__}"
    if result.returncode != 0:
        return None, f"exit-{result.returncode}"
    return result.stdout.splitlines(), None


def journal_lines(now):
    fixture = os.environ.get("AIDEVOPS_LOGIND_FIXTURE")
    if fixture:
        try:
            return Path(fixture).read_text(encoding="utf-8").splitlines(), None
        except OSError as exc:
            return [], f"fixture-read-failed:{type(exc).__name__}"
    lines, error = run_trusted_command(
        "journalctl",
        ["--since", "366 days ago", "-u", "systemd-logind.service", "--no-pager", "-o", "short-iso"],
    )
    return (lines or []), f"journal-read-failed:{error}" if error else None


def parse_last_local_timestamp(value):
    for format_string in ("%a %b %d %H:%M:%S %z %Y", "%a %b %d %H:%M:%S %Y"):
        try:
            # The no-offset form is intentionally naive: timestamp() applies the
            # host local timezone and historical DST rules used by GNU last -F.
            return dt.datetime.strptime(value, format_string).timestamp()
        except ValueError:
            continue
    return None


def read_wtmp_lines(user, journal_reason):
    fixture = os.environ.get("AIDEVOPS_LAST_FIXTURE")
    if fixture:
        try:
            return Path(fixture).read_text(encoding="utf-8").splitlines(), None
        except OSError as exc:
            return None, f"fixture-read-failed:{type(exc).__name__}"
    lines, error = run_trusted_command("last", ["-F", "-s", "-365days", user])
    return lines, f"{journal_reason};wtmp-read-failed:{error}" if error else None


def parse_wtmp_line(line, now):
    interval = None
    malformed = False
    ignored = not line.strip() or "wtmp begins" in line or line.startswith(("reboot", "shutdown"))
    if not ignored:
        structured = re.match(r"^([0-9]+)\|([0-9]+)$", line.strip())
        if structured:
            interval = (float(structured.group(1)), float(structured.group(2)))
        else:
            dates = re.findall(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2}\s+[0-9]{1,2} [0-9:]{8}(?: [+-][0-9]{4})? [0-9]{4}", line)
            try:
                left = parse_last_local_timestamp(dates[0]) if dates else None
                right = now if "still logged in" in line else parse_last_local_timestamp(dates[1]) if len(dates) >= 2 else None
                if left is not None and right is not None and right > left:
                    interval = (left, right)
                else:
                    malformed = True
            except (TypeError, ValueError):
                malformed = True
    return interval, malformed


def parse_wtmp_lines(lines, now):
    intervals = []
    skipped = 0
    for line in lines:
        interval, malformed = parse_wtmp_line(line, now)
        if interval:
            intervals.append(interval)
        skipped += int(malformed)
    return intervals, skipped


def wtmp_collection(now, user, journal_reason):
    lines, error = read_wtmp_lines(user, journal_reason)
    if error:
        source = "linux-wtmp" if error.startswith("fixture-read-failed:") else "linux-logind+wtmp"
        return {"status": "unavailable", "source": source, "reason": error, "intervals": []}
    intervals, skipped = parse_wtmp_lines(lines, now)
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
        "earliest_epoch": min(left for left, _ in intervals),
        "freshness_hours": round(freshness, 1),
        "skipped_rows": skipped,
        "observation_epochs": [],
        "coverage_start_epoch": min(left for left, _ in intervals),
        "coverage_end_epoch": max(right for _, right in intervals),
    }


def linux_is_active(state):
    return state["lid_open"] and any(not locked for locked in state["sessions"].values())


def apply_linux_message(state, message, user):
    recognized = True
    match = SESSION_NEW.search(message)
    if match and match.group(2) == user:
        state["sessions"][match.group(1).rstrip(".")] = False
    elif "Lid closed" in message:
        state["lid_open"] = False
    elif "Lid opened" in message:
        state["lid_open"] = True
    else:
        lowered = message.lower()
        lock_match = SESSION_ID.search(message) if "locked" in lowered else None
        lock_session_id = lock_match.group(1).rstrip(".") if lock_match else ""
        end_match = SESSION_END.search(message)
        end_session_id = end_match.group(1).rstrip(".") if end_match else ""
        if lock_session_id in state["sessions"]:
            state["sessions"][lock_session_id] = "unlocked" not in lowered
        elif end_session_id in state["sessions"]:
            state["sessions"].pop(end_session_id, None)
        else:
            recognized = False
    return recognized


def parse_linux_journal_line(line, now):
    first = line.split(None, 1)
    timestamp = parse_timestamp(first[0]) if len(first) == 2 else None
    if timestamp is None or timestamp > now:
        return None
    return timestamp, first[1]


def debug_linux_event(timestamp, before, after, state, message):
    if os.environ.get("AIDEVOPS_SCREEN_TIME_DEBUG") == "1":
        print(
            f"screen-time event ts={timestamp} before={before} after={after} sessions={state['sessions']} lid_open={state['lid_open']} message={message}",
            file=sys.stderr,
        )


def apply_linux_event(state, message, user, timestamp, opened, intervals):
    before = linux_is_active(state)
    if not apply_linux_message(state, message, user):
        return opened, before, False
    after = linux_is_active(state)
    debug_linux_event(timestamp, before, after, state, message)
    if before != after:
        if before and opened is not None:
            intervals.append((opened, timestamp))
        opened = timestamp if after else None
    return opened, after, True


def collect_linux_events(lines, now, user):
    state = {"sessions": {}, "lid_open": True}
    intervals = []
    observation_epochs = []
    opened = None
    active = False
    for line in lines:
        event = parse_linux_journal_line(line, now)
        if event is None:
            continue
        timestamp, message = event
        opened, active, recognized = apply_linux_event(state, message, user, timestamp, opened, intervals)
        if recognized:
            observation_epochs.append(timestamp)
    if active and opened is not None:
        intervals.append((opened, now))
    return union_intervals(intervals, now - WINDOWS["year"], now), observation_epochs


def linux_collection(now, user):
    lines, error = journal_lines(now)
    if error:
        return wtmp_collection(now, user, error)
    intervals, observation_epochs = collect_linux_events(lines, now, user)
    if not observation_epochs:
        return wtmp_collection(now, user, "journal-readable-no-user-observations")
    latest = max(observation_epochs)
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "linux-systemd-logind:session-lid-lock-state",
        "reason": "source-observations",
        "intervals": intervals,
        "observations": len(observation_epochs),
        "latest_epoch": latest,
        "earliest_epoch": min(observation_epochs),
        "freshness_hours": round(freshness, 1),
        "observation_epochs": observation_epochs,
        "coverage_start_epoch": min(observation_epochs),
        "coverage_end_epoch": max(observation_epochs),
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
    skipped = 0
    if not history_path or not history_path.exists():
        return rows, skipped
    try:
        for line in history_path.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
                if not isinstance(row, dict) or isinstance(row.get("screen_hours"), bool):
                    raise ValueError("invalid history row")
                date = dt.date.fromisoformat(str(row.get("date")))
                hours = float(row.get("screen_hours"))
                if hours < 0 or not math.isfinite(hours):
                    raise ValueError("invalid history row")
                rows[date] = (min(24.0, hours), row)
            except (ValueError, TypeError, json.JSONDecodeError):
                skipped += 1
    except OSError:
        return {}, skipped + 1
    return rows, skipped


def history_period(rows, now, days, skipped_rows=0):
    end_date = local_date(now)
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
        "skipped_history_rows": skipped_rows,
    }


def profile_payload(collection, history_path, now):
    periods = {name: period_payload(collection, now, seconds) for name, seconds in WINDOWS.items()}
    history, skipped_history_rows = read_history(history_path, now)
    for name, days in (("day", 1), ("week", 7), ("month", 28)):
        if periods[name]["status"] == "unavailable":
            fallback = history_period(history, now, days, skipped_history_rows)
            if fallback:
                periods[name] = fallback
    year_history = history_period(history, now, 365, skipped_history_rows)
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
        "history_skipped_rows": skipped_history_rows,
    }


def collect(args):
    if args.os_type == "Darwin":
        return macos_collection(Path(args.db), args.now)
    if args.os_type == "Linux":
        return linux_collection(args.now, args.user)
    return {"status": "unavailable", "source": "unsupported-platform", "reason": args.os_type, "intervals": []}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("profile", "query", "date", "earliest", "apps", "next-date", "history-summary"))
    parser.add_argument("--os-type", required=True)
    parser.add_argument("--db", default="")
    parser.add_argument("--history", default="")
    parser.add_argument("--days", type=int, default=1)
    parser.add_argument("--date", default="")
    parser.add_argument("--now", type=float, default=float(os.environ.get("AIDEVOPS_SCREEN_TIME_NOW_EPOCH", "0") or 0))
    parser.add_argument("--user", default=os.environ.get("AIDEVOPS_SCREEN_TIME_USER", getpass.getuser()))
    args = parser.parse_args()
    if hasattr(time, "tzset"):
        time.tzset()
    if not args.now:
        args.now = dt.datetime.now(dt.timezone.utc).timestamp()
    if args.command == "apps":
        print(json.dumps(macos_app_stats(Path(args.db), args.now), sort_keys=True))
        return 0
    if args.command == "next-date":
        print((dt.date.fromisoformat(args.date) + dt.timedelta(days=1)).isoformat())
        return 0
    if args.command == "history-summary":
        rows, skipped = read_history(Path(args.history) if args.history else None, args.now)
        print(json.dumps({"valid_rows": len(rows), "skipped_rows": skipped, "earliest": min(rows).isoformat() if rows else None, "latest": max(rows).isoformat() if rows else None, "total_hours": round(sum(value[0] for value in rows.values()), 1)}, sort_keys=True))
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
        start, end = local_day_bounds(target)
        observations = collection.get("observation_epochs", [])
        intervals = collection.get("intervals", [])
        coverage_end = collection.get("coverage_end_epoch")
        explicit_event = any(start <= timestamp < end for timestamp in observations)
        interval_overlap = any(right > start and left < end for left, right in intervals)
        within_coverage = coverage_end is not None and start <= coverage_end
        observed_date = within_coverage and (explicit_event or interval_overlap)
        hours = None if collection.get("status") == "unavailable" or not observed_date else round(min(24 * 3600, interval_seconds(intervals, start, end)) / 3600, 1)
        print("unavailable" if hours is None else hours)
    else:
        starts = [left for left, _ in collection.get("intervals", [])]
        earliest = collection.get("earliest_epoch")
        if earliest is None and starts:
            earliest = min(starts)
        print(local_date(earliest).isoformat() if earliest is not None else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
