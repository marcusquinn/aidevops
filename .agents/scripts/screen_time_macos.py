"""Read-only macOS Knowledge database screen-time collection."""

from __future__ import annotations

import datetime as dt
import sqlite3

from screen_time_interval_common import DAY, WINDOWS, interval_seconds, local_date, safe_core_epoch, safe_float, union_intervals


def unavailable(reason, source="macos-knowledge-db"):
    return {"status": "unavailable", "source": source, "reason": reason, "intervals": []}


def read_knowledge_rows(db_path):
    if not db_path.is_file():
        return None, None, "database-missing"
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=5) as connection:
            backlit = connection.execute(
                "SELECT ZSTARTDATE, ZENDDATE, ZVALUEINTEGER FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/display/isBacklit' ORDER BY ZSTARTDATE"
            ).fetchall()
            apps = connection.execute(
                "SELECT ZSTARTDATE, ZENDDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/app/usage' ORDER BY ZSTARTDATE"
            ).fetchall()
        return backlit, apps, None
    except (OSError, sqlite3.Error) as exc:
        return None, None, f"database-read-failed:{type(exc).__name__}"


def parse_backlit_rows(rows):
    """Parse completed ``/display/isBacklit`` spans as ``(start, end, on)``.

    Each row records the state the display held from ZSTARTDATE to ZENDDATE and
    is written when that span ends, so ZCREATIONDATE is the end of the span, not
    the start of the next one. Reading ``(ZCREATIONDATE, value)`` as a state
    transition counted every display-off span as on and vice versa (GH#37492).
    """
    parsed = []
    for start, end, state in rows:
        left = safe_core_epoch(start)
        right = safe_core_epoch(end)
        numeric_state = safe_float(state)
        if left is not None and right is not None and numeric_state is not None and right >= left:
            parsed.append((left, right, bool(numeric_state)))
    return parsed


def parse_app_rows(rows):
    parsed = []
    for start, end in rows:
        left = safe_core_epoch(start)
        right = safe_core_epoch(end)
        if left is not None and right is not None and right > left:
            parsed.append((left, right))
    return parsed


def active_dates(intervals, now, window_days=28):
    dates = set()
    for left, right in union_intervals(intervals, now - window_days * DAY, now):
        cursor = local_date(left)
        final = local_date(max(left, right - 1))
        if cursor is None or final is None:
            continue
        while cursor <= final:
            dates.add(cursor)
            cursor += dt.timedelta(days=1)
    return dates


def app_source_is_richer(backlit_intervals, app_intervals, now):
    backlit_dates = active_dates(backlit_intervals, now)
    app_dates = active_dates(app_intervals, now)
    if len(app_dates) <= len(backlit_dates):
        return False
    materially_more_days = len(app_dates) >= max(len(backlit_dates) + 2, len(backlit_dates) * 2)
    backlit_seconds = interval_seconds(backlit_intervals, now - 28 * DAY, now)
    app_seconds = interval_seconds(app_intervals, now - 28 * DAY, now)
    materially_more_time = app_seconds > max(3600, backlit_seconds * 1.5)
    return materially_more_days or materially_more_time


def source_payload(selection):
    raw_intervals = selection["raw_intervals"]
    latest = selection["latest"]
    starts = [left for left, _ in raw_intervals]
    ends = [right for _, right in raw_intervals]
    return {
        "source": selection["source"],
        "intervals": selection["intervals"],
        "observations": len(raw_intervals),
        "latest_epoch": latest,
        "earliest_epoch": min(starts, default=latest),
        "observation_epochs": selection["observation_epochs"],
        "coverage_start_epoch": min(starts, default=latest),
        "coverage_end_epoch": max(ends, default=latest),
        "freshness_hours": None,
    }


def choose_source(backlit, apps, now):
    earliest = now - WINDOWS["year"]
    backlit_intervals = union_intervals([(left, right) for left, right, on in backlit if on], earliest, now)
    app_intervals = union_intervals(apps, earliest, now)
    latest_backlit = max((item[1] for item in backlit), default=None)
    latest_app = max((item[1] for item in apps), default=None)
    recent_backlit = latest_backlit is not None and now - latest_backlit <= 3 * DAY
    use_backlit = recent_backlit and not app_source_is_richer(backlit_intervals, app_intervals, now)
    raw_backlit = [(left, right) for left, right, _ in backlit]
    backlit_observations = [right for _, right, _ in backlit]
    if use_backlit:
        return source_payload({"source": "macos-knowledge-db:/display/isBacklit", "intervals": backlit_intervals, "raw_intervals": raw_backlit, "latest": latest_backlit, "observation_epochs": backlit_observations})
    if apps:
        return source_payload({"source": "macos-knowledge-db:/app/usage-union", "intervals": app_intervals, "raw_intervals": apps, "latest": latest_app, "observation_epochs": []})
    if backlit:
        return source_payload({"source": "macos-knowledge-db:/display/isBacklit-stale", "intervals": backlit_intervals, "raw_intervals": raw_backlit, "latest": latest_backlit, "observation_epochs": backlit_observations})
    return None


def macos_collection(db_path, now):
    backlit_rows, app_rows, error = read_knowledge_rows(db_path)
    if error:
        return unavailable(error)
    backlit = parse_backlit_rows(backlit_rows)
    apps = parse_app_rows(app_rows)
    selected = choose_source(backlit, apps, now)
    if selected is None:
        return unavailable("empty-readable-database", "macos-knowledge-db:no-observations")
    freshness = max(0.0, (now - selected["latest_epoch"]) / 3600)
    selected.update({
        "status": "stale" if freshness > 72 else "ok",
        "reason": "source-observations",
        "freshness_hours": round(freshness, 1),
    })
    return selected
