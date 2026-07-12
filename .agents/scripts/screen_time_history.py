"""Screen-time period payloads and history fallback aggregation."""

from __future__ import annotations

import datetime as dt
import json
import math

from screen_time_interval_common import WINDOWS, completed_day_window, interval_seconds, local_date


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
    window_days = (end - start) / 86400
    days = min(window_days, max(1.0, (observed_end - observed_start) / 86400 + 1.0))
    return round(days, 1), round(days / window_days * 100, 1)


def bounded_period_payload(collection, start, end, semantics="rolling-clock-window"):
    observed_days, coverage_pct = coverage(collection, start, end)
    status = collection.get("status", "unavailable")
    hours = None if status == "unavailable" else round(interval_seconds(collection.get("intervals", []), start, end) / 3600, 1)
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
        "period_start_epoch": start,
        "period_end_epoch": end,
        "period_semantics": semantics,
    }


def period_payload(collection, now, seconds):
    return bounded_period_payload(collection, now - seconds, now)


def parse_history_row(line):
    try:
        row = json.loads(line)
        if not isinstance(row, dict) or isinstance(row.get("screen_hours"), bool):
            return None
        date = dt.date.fromisoformat(str(row.get("date")))
        hours = float(row.get("screen_hours"))
        if hours < 0 or not math.isfinite(hours):
            return None
        return date, (min(24.0, hours), row)
    except (ValueError, TypeError, json.JSONDecodeError):
        return None


def read_history(history_path, _now):
    rows = {}
    skipped = 0
    if history_path is None or not history_path.is_file():
        return rows, skipped
    try:
        lines = history_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}, 1
    for line in lines:
        parsed = parse_history_row(line)
        if parsed is None:
            skipped += 1
        else:
            rows[parsed[0]] = parsed[1]
    return rows, skipped


def history_period(rows, now, days, skipped_rows=0):
    end_date = local_date(now)
    if end_date is None:
        return None
    start_date = end_date - dt.timedelta(days=days)
    selected = [(date, value) for date, value in rows.items() if start_date <= date < end_date]
    if not selected:
        return None
    dates = [item[0] for item in selected]
    total = round(sum(item[1][0] for item in selected), 1)
    span = max(1, (max(dates) - min(dates)).days + 1)
    latest_age = (end_date - max(dates)).days
    start_epoch, end_epoch = completed_day_window(now, days)
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
        "period_start_epoch": start_epoch,
        "period_end_epoch": end_epoch,
        "period_semantics": "completed-local-calendar-days",
    }


def apply_short_history(periods, history, now, skipped):
    for name, days in (("day", 1), ("week", 7), ("month", 28)):
        fallback = history_period(history, now, days, skipped)
        if not fallback:
            continue
        live_coverage = periods[name].get("coverage_pct", 0) or 0
        permission_free_proxy = periods[name].get("source") == "macos-pmset-display-assertions"
        better_coverage = fallback["coverage_pct"] > live_coverage
        equal_higher_confidence = permission_free_proxy and fallback["coverage_pct"] >= live_coverage
        if periods[name]["status"] == "unavailable" or better_coverage or equal_higher_confidence:
            if periods[name]["status"] == "unavailable":
                reason = "live-source-unavailable"
            elif equal_higher_confidence and not better_coverage:
                reason = "higher-confidence-observed-history"
            else:
                reason = "richer-calendar-coverage"
            periods[name] = dict(fallback, reason=reason)


def estimated_year(periods, history, now, skipped):
    year = history_period(history, now, 365, skipped)
    if year and year.get("calendar_span_days", 0) >= 330:
        return year
    if year and year.get("coverage_days", 0) > 0:
        estimate = min(8760.0, year["hours"] / year["calendar_span_days"] * 365)
        return dict(year, hours=round(estimate, 1), estimated=True, reason="calendar-span-extrapolation")
    month = periods["month"]
    if periods["year"]["status"] != "unavailable" and month["coverage_days"] > 0:
        estimate = min(8760.0, (month["hours"] or 0) / month["coverage_days"] * 365)
        return dict(month, hours=round(estimate, 1), estimated=True, reason="observed-calendar-coverage-extrapolation")
    return periods["year"]


def profile_payload(collection, history_path, now):
    day_counts = {"day": 1, "week": 7, "month": 28, "year": 365}
    periods = {}
    for name in WINDOWS:
        start, end = completed_day_window(now, day_counts[name])
        periods[name] = bounded_period_payload(collection, start, end, "completed-local-calendar-days")
    history, skipped = read_history(history_path, now)
    apply_short_history(periods, history, now, skipped)
    periods["year"] = estimated_year(periods, history, now, skipped)
    return {
        "today_hours": periods["day"]["hours"],
        "week_hours": periods["week"]["hours"],
        "month_hours": periods["month"]["hours"],
        "year_hours": periods["year"]["hours"],
        "month_note": periods["month"]["source"],
        "periods": periods,
        "collection_status": collection.get("status", "unavailable"),
        "history_skipped_rows": skipped,
    }
