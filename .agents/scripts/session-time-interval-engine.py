#!/usr/bin/env python3
"""Aggregate assistant session observations once for multiple time windows."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

DAY_MS = 86400000
WINDOWS = {
    "day": DAY_MS,
    "week": 7 * DAY_MS,
    "28d": 28 * DAY_MS,
    "month": 30 * DAY_MS,
    "quarter": 90 * DAY_MS,
    "year": 365 * DAY_MS,
}
WORKER_PATTERNS = [
    re.compile(pattern, re.I)
    for pattern in (
        r"^Issue #\d+", r"^PR #\d+", r"^Fix PR\b", r"^Review PR\b",
        r"^Supervisor Pulse", r"/full-loop", r"^dispatch:", r"^Worker:",
        r"^t\d+[.\-:]", r"^escalation-", r"^health-check$", r"failing CI\b",
        r"CI fail", r"CHANGES_REQUESTED", r"CodeRabbit review", r"address review",
        r"review feedback", r"^Fix qlty\b", r"^Gemini feedback\b",
        r"^observability-only headless session$",
    )
]
TEMP_PATHS = (
    re.compile(r"^/private/tmp/opencode(?:[.-].*)?$"),
    re.compile(r"^/tmp/opencode(?:[.-].*)?$"),
    re.compile(r"^/var/folders/.*/T/opencode.*$"),
)


def path_matches(candidate, root):
    if not root:
        return True
    if not candidate:
        return False
    return candidate == root or candidate.startswith(root + ".") or candidate.startswith(root + "-") or candidate.startswith(root + "/")


def classify(title, directory):
    if any(pattern.search(directory or "") for pattern in TEMP_PATHS):
        return "worker"
    if any(pattern.search(title or "") for pattern in WORKER_PATTERNS):
        return "worker"
    return "interactive"


def union(intervals, start, end):
    clipped = sorted((max(start, left), min(end, right)) for left, right in intervals if right > start and left < end)
    result = []
    for left, right in clipped:
        if right <= left:
            continue
        if result and left <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], right))
        else:
            result.append((left, right))
    return result


def duration(intervals, start, end):
    return sum(right - left for left, right in union(intervals, start, end))


def db_paths(home, explicit):
    if explicit:
        return [Path(explicit)]
    paths = [home / ".local/share/opencode/opencode.db", home / ".local/share/opencode/opencode-archive.db"]
    work = Path(os.environ.get("AIDEVOPS_WORK_DIR", home / ".aidevops/.agent-workspace/work"))
    paths.extend(Path(item) for item in glob.glob(str(work / "opencode-interactive/*/opencode/opencode.db")))
    return [item for item in paths if item.is_file()]


def note_scan(db_path):
    counter = os.environ.get("AIDEVOPS_SESSION_SCAN_COUNTER")
    if counter:
        with open(counter, "a", encoding="utf-8") as handle:
            handle.write(str(db_path) + "\n")


def query_session_db(db_path, root, since):
    note_scan(db_path)
    query = """
        SELECT s.id, s.title, s.directory, m.time_created, m.data
        FROM session s JOIN message m ON m.session_id=s.id
        WHERE s.parent_id IS NULL AND m.time_created >= ?
        ORDER BY s.id, m.time_created
    """
    sessions = {}
    try:
        with sqlite3.connect(db_path, timeout=5) as connection:
            for session_id, title, directory, created, data in connection.execute(query, (since,)):
                if not path_matches(directory, root):
                    continue
                row = sessions.setdefault(session_id, {
                    "session_id": session_id, "title": title or "", "directory": directory or "",
                    "human": [], "machine": [], "first": int(created), "last": int(created), "previous_role": None,
                    "previous_completed": None,
                })
                try:
                    payload = json.loads(data or "{}")
                except json.JSONDecodeError:
                    payload = {}
                role = payload.get("role")
                completed = payload.get("time", {}).get("completed")
                completed = int(completed) if isinstance(completed, (int, float)) else None
                created = int(created)
                if role == "user" and row["previous_role"] == "assistant" and row["previous_completed"]:
                    gap = created - row["previous_completed"]
                    if 0 < gap <= 3600000:
                        row["human"].append((row["previous_completed"], created))
                if role == "assistant" and completed and completed > created:
                    row["machine"].append((created, completed))
                row["previous_role"] = role
                row["previous_completed"] = completed
                row["first"] = min(row["first"], created)
                row["last"] = max(row["last"], completed or created)
    except sqlite3.Error:
        return [], False
    for row in sessions.values():
        row.pop("previous_role", None)
        row.pop("previous_completed", None)
    return list(sessions.values()), True


def parse_iso_ms(value):
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return int(parsed.timestamp() * 1000)
    except ValueError:
        return None


def query_observability(home, root, since, now):
    db_path = Path(os.environ.get("AIDEVOPS_OBS_DB_FILE", home / ".aidevops/.agent-workspace/observability/llm-requests.db"))
    if not db_path.is_file():
        return {}, False
    rows = {}
    try:
        with sqlite3.connect(db_path, timeout=5) as connection:
            query = "SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests WHERE duration_ms > 0"
            for timestamp, session_id, duration_ms, project_path in connection.execute(query):
                if not session_id or not path_matches(project_path, root):
                    continue
                end = parse_iso_ms(timestamp)
                if end is None or end < since:
                    continue
                end = min(now, end)
                start = max(since, end - int(duration_ms))
                if end <= start:
                    continue
                row = rows.setdefault(session_id, {"intervals": [], "directory": project_path or ""})
                row["intervals"].append((start, end))
    except sqlite3.Error:
        return {}, False
    return rows, True


def aggregate(sessions, obs_rows, since, now, sources_ok):
    population = {}
    for row in sessions:
        population[row["session_id"]] = row
    for session_id, obs in obs_rows.items():
        if session_id not in population:
            population[session_id] = {
                "session_id": session_id, "title": "observability-only headless session",
                "directory": obs["directory"], "human": [], "machine": [],
                "first": min(left for left, _ in obs["intervals"]),
                "last": max(right for _, right in obs["intervals"]),
            }

    human_by_type = {"interactive": [], "worker": []}
    machine_by_type = {"interactive": 0, "worker": 0}
    counts = {"interactive": 0, "worker": 0}
    first_seen = []
    last_seen = []
    for session_id, row in population.items():
        human = union(row.get("human", []), since, now)
        machine_source = obs_rows.get(session_id, {}).get("intervals") or row.get("machine", [])
        machine = union(machine_source, since, now)
        if not human and not machine and row.get("last", 0) < since:
            continue
        session_type = classify(row.get("title", ""), row.get("directory", ""))
        counts[session_type] += 1
        human_by_type[session_type].extend(human)
        machine_by_type[session_type] += sum(right - left for left, right in machine)
        first_seen.append(max(since, row.get("first", since)))
        last_seen.append(min(now, row.get("last", now)))

    interactive_human = duration(human_by_type["interactive"], since, now)
    worker_human = duration(human_by_type["worker"], since, now)
    total_human = duration(human_by_type["interactive"] + human_by_type["worker"], since, now)
    interactive_machine = machine_by_type["interactive"]
    worker_machine = machine_by_type["worker"]
    observed_days = round(max(0, max(last_seen) - min(first_seen)) / DAY_MS, 1) if first_seen and last_seen else 0

    def hours(milliseconds):
        return round(milliseconds / 3600000, 1)

    return {
        "interactive_sessions": counts["interactive"],
        "interactive_human_hours": hours(interactive_human),
        "interactive_machine_hours": hours(interactive_machine),
        "worker_sessions": counts["worker"],
        "worker_human_hours": hours(worker_human),
        "worker_machine_hours": hours(worker_machine),
        "total_human_hours": hours(total_human),
        "total_machine_hours": hours(interactive_machine + worker_machine),
        "total_sessions": counts["interactive"] + counts["worker"],
        "observed_days": observed_days,
        "status": "ok" if sources_ok else "unavailable",
        "provenance": "session-message-intervals+observability-request-intervals" if obs_rows else "session-message-intervals",
        "human_attention_semantics": "unioned wall-clock intervals",
        "machine_work_semantics": "additive per-session generation intervals",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="")
    parser.add_argument("--all-dirs", action="store_true")
    parser.add_argument("--db-path", default="")
    parser.add_argument("--period", default="month")
    parser.add_argument("--now-ms", type=int, default=int(time.time() * 1000))
    args = parser.parse_args()
    root = "" if args.all_dirs else os.path.abspath(args.repo or ".")
    home = Path.home()
    maximum_since = args.now_ms - WINDOWS["year"]
    sessions = []
    source_ok = False
    seen = set()
    for db_path in db_paths(home, args.db_path):
        queried, ok = query_session_db(db_path, root, maximum_since)
        source_ok = source_ok or ok
        for row in queried:
            if row["session_id"] not in seen:
                sessions.append(row)
                seen.add(row["session_id"])
    obs_rows, obs_ok = query_observability(home, root, maximum_since, args.now_ms)
    source_ok = source_ok or obs_ok

    periods = ["day", "week", "28d", "year"] if args.period == "profile" else (
        ["day", "week", "month", "quarter", "year"] if args.period == "all" else [args.period]
    )
    result = {
        period: aggregate(sessions, obs_rows, args.now_ms - WINDOWS.get(period, WINDOWS["month"]), args.now_ms, source_ok)
        for period in periods
    }
    print(json.dumps(result if len(periods) > 1 else result[periods[0]], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
