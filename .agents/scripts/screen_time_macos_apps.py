"""Top-app attribution for macOS screen-time observations."""

from __future__ import annotations

import heapq
import json
import os
import sqlite3
import time
from pathlib import Path

from screen_time_interval_common import CORE_DATA_EPOCH, DAY, safe_core_epoch


def read_app_stat_rows(db_path, now):
    if not db_path.is_file():
        return [], "database-missing"
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=5) as connection:
            rows = connection.execute(
                "SELECT ZVALUESTRING, ZSTARTDATE, ZENDDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME='/app/usage' AND ZVALUESTRING IS NOT NULL "
                "AND ZENDDATE > ? AND ZSTARTDATE < ? ORDER BY ZSTARTDATE",
                (now - 28 * DAY - CORE_DATA_EPOCH, now - CORE_DATA_EPOCH),
            ).fetchall()
        return rows, None
    except (OSError, sqlite3.Error) as exc:
        return [], f"database-read-failed:{type(exc).__name__}"


def parse_app_stat_rows(rows, now):
    month_start = now - 28 * DAY
    parsed = []
    for bundle, start, end in rows:
        original_start = safe_core_epoch(start)
        original_end = safe_core_epoch(end)
        if original_start is None or original_end is None or original_end <= original_start:
            continue
        left = max(month_start, original_start)
        right = min(now, original_end)
        if right > left:
            parsed.append((str(bundle), left, right, original_start))
    return parsed


def interval_boundaries(intervals, month_start, now):
    starts, ends, boundaries = {}, {}, {month_start, now}
    for interval_id, (bundle, left, right, original_start) in enumerate(intervals):
        starts.setdefault(left, []).append((interval_id, bundle, original_start))
        ends.setdefault(right, []).append(interval_id)
        boundaries.update((left, right))
    return starts, ends, sorted(boundaries)


def update_active_apps(context, starting, ending):
    for interval_id in ending:
        context["active"].discard(interval_id)
    for interval_id, bundle, original_start in starting:
        context["active"].add(interval_id)
        heapq.heappush(context["latest_heap"], (-original_start, -interval_id, interval_id, bundle))
    while context["latest_heap"] and context["latest_heap"][0][2] not in context["active"]:
        heapq.heappop(context["latest_heap"])


def attribute_segment(context, left, right):
    if not context["latest_heap"] or right <= left:
        return
    bundle = context["latest_heap"][0][3]
    context["stats"]["attributed_segments"] += 1
    now = context["now"]
    for name, window_start in (("today", now - DAY), ("week", now - 7 * DAY), ("month", now - 28 * DAY)):
        overlap = right - max(left, window_start)
        if overlap > 0:
            totals = context["totals"][name]
            totals[bundle] = totals.get(bundle, 0) + overlap


def attribute_app_totals(intervals, now):
    starts, ends, ordered = interval_boundaries(intervals, now - 28 * DAY, now)
    context = {
        "active": set(),
        "latest_heap": [],
        "totals": {name: {} for name in ("today", "week", "month")},
        "stats": {"boundaries": len(ordered), "attributed_segments": 0, "max_active": 0},
        "now": now,
    }
    for left, right in zip(ordered, ordered[1:]):
        update_active_apps(context, starts.get(left, []), ends.get(left, []))
        context["stats"]["max_active"] = max(context["stats"]["max_active"], len(context["active"]))
        attribute_segment(context, left, right)
    return context["totals"], context["stats"]


def app_result(totals):
    result = []
    month_items = sorted(totals["month"].items(), key=lambda item: (-item[1], item[0]))[:10]
    for bundle, month_seconds in month_items:
        row = {"bundle": bundle, "month_seconds": round(month_seconds)}
        for name in ("today", "week", "month"):
            denominator = sum(totals[name].values())
            row[f"{name}_pct"] = round(totals[name].get(bundle, 0) / denominator * 100) if denominator else 0
        result.append(row)
    return result


def write_instrumentation(rows, intervals, stats, started_at):
    instrument_file = os.environ.get("AIDEVOPS_APP_STATS_INSTRUMENT_FILE")
    if not instrument_file:
        return
    payload = dict(stats, rows_selected=len(rows), valid_intervals=len(intervals))
    payload["elapsed_ms"] = round((time.perf_counter() - started_at) * 1000, 3)
    Path(instrument_file).write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")


def macos_app_stats(db_path, now):
    started_at = time.perf_counter()
    rows, error = read_app_stat_rows(db_path, now)
    if error:
        return []
    intervals = parse_app_stat_rows(rows, now)
    totals, stats = attribute_app_totals(intervals, now)
    write_instrumentation(rows, intervals, stats, started_at)
    return app_result(totals)
