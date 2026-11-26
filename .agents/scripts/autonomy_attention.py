#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only local human-prompt counts from OpenCode session databases (counts only)."""

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import sqlite3

DEFAULT_OPENCODE_DB = Path.home() / ".local/share/opencode/opencode.db"
DEFAULT_INTERACTIVE_ROOT = Path.home() / ".aidevops/.agent-workspace/work/opencode-interactive"

SQL = """select m.id, m.session_id, s.directory, m.time_created, p.data
  from message m join session s on s.id = m.session_id join part p on p.message_id = m.id
  where s.parent_id is null and m.time_created >= ? and m.time_created < ?
    and s.directory not like '%/tmp/%' and s.directory not like '%/T/%'
    and s.directory not like '%-feature-auto-%' and s.directory not like '%-ci-repair-%'
    and s.directory not like '%_worktrees/%-pr%-review-%'
    and s.directory not like '%/.aidevops/%'
    and json_extract(m.data, '$.role') = 'user'
    and json_extract(p.data, '$.type') = 'text'
    and coalesce(json_extract(p.data, '$.synthetic'), 0) = 0"""
NUDGE = re.compile(r"^\s*(continue|go on|carry on|resume|proceed|ok|yes)\W*$", re.I)

NOTES = [
    "Attention counts are local OpenCode sessions on this machine only; Claude Code sessions and other machines are not counted.",
    "Human prompts approximate user effort: top-level sessions, non-synthetic text, automated session directories excluded.",
    "A message with several text parts counts once; it is a nudge only when every text part is a bare nudge.",
    "Framework share uses sessions in the framework repo directory or its linked worktrees.",
]


def opencode_db_paths():
    """Same discovery as report-token-use-helper.py _opencode_db_paths()."""
    override = os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB")
    if override:
        return [Path(override)]
    root = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_INTERACTIVE_ROOT", DEFAULT_INTERACTIVE_ROOT))
    paths = [DEFAULT_OPENCODE_DB]
    if root.is_dir():
        for project in sorted(root.iterdir()):
            for name in ("opencode.db", "opencode-archive.db"):
                candidate = project / "opencode" / name
                if candidate.is_file():
                    paths.append(candidate)
    return paths


def is_framework(directory, name):
    path = (directory or "").rstrip("/")
    return path.rsplit("/", 1)[-1] == name or ("/_worktrees/" + name + "-") in path + "/"


def _millis(day):
    return int(datetime(day.year, day.month, day.day, tzinfo=timezone.utc).timestamp() * 1000)


def _read_db(db_path, start_ms, stop_ms):
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    try:
        return con.execute(SQL, (start_ms, stop_ms)).fetchall()
    finally:
        con.close()


def scan(windows, framework_name):
    """Return per-week prompt counts, scanned and skipped DB counts."""
    start_ms, stop_ms = _millis(windows[0][0]), _millis(windows[-1][1])
    messages = {}  # message id -> [directory, time_created, every text part is a nudge]
    skipped = scanned = 0
    for db_path in opencode_db_paths():
        if not db_path.is_file():
            continue
        try:
            rows = _read_db(db_path, start_ms, stop_ms)
        except sqlite3.Error:
            skipped += 1
            continue
        scanned += 1
        for message_id, _session, directory, created, data in rows:
            try:
                text = json.loads(data).get("text") or ""
            except (ValueError, AttributeError):
                text = ""
            entry = messages.setdefault(message_id, [directory, created, True])
            entry[2] = entry[2] and bool(NUDGE.match(text))
    weeks = {str(w[0]): {"human_prompts": 0, "nudges": 0, "framework_prompts": 0} for w in windows}
    for directory, created, nudge in messages.values():
        for start, stop in windows:
            if _millis(start) <= created < _millis(stop):
                week = weeks[str(start)]
                week["human_prompts"] += 1
                week["nudges"] += nudge
                week["framework_prompts"] += is_framework(directory, framework_name)
                break
    return weeks, scanned, skipped


def _fmt(value, percent=False):
    if value is None:
        return "n/a"
    return f"{value:.1%}" if percent else str(round(value, 3))


def print_attention(section):
    print("\nHuman attention (local OpenCode, this machine only)")
    print("Week | Prompts | Nudges | Framework share (target <=20%) | "
          "Merged PRs/prompt excl. framework | incl. framework")
    for row in section["weeks"]:
        print(" | ".join([row["week_start"], str(row["human_prompts"]), str(row["nudges"]),
                          _fmt(row["framework_share"], True),
                          _fmt(row["merged_prs_per_prompt_excluding_framework"]),
                          _fmt(row["merged_prs_per_prompt_including_framework"])]))
    for note in section["notes"]:
        print("Note: " + note)


def attention(rows, windows, framework, ratio):
    """Build the attention section; rows are the existing weekly GitHub rows."""
    weeks, scanned, skipped = scan(windows, framework.split("/")[1])
    out = []
    for start, stop in windows:
        values = weeks[str(start)]
        prompts = values["human_prompts"]
        week_rows = [r for r in rows if r["week_start"] == str(start)]
        managed = sum(r["all"] for r in week_rows if r["scope"] != framework)
        with_framework = sum(r["all"] for r in week_rows)
        out.append({
            "week_start": str(start), "week_end": str(stop - timedelta(days=1)),
            **values,
            "framework_share": ratio(values["framework_prompts"], prompts),
            "merged_prs_excluding_framework": managed,
            "merged_prs_including_framework": with_framework,
            "merged_prs_per_prompt_excluding_framework": ratio(managed, prompts),
            "merged_prs_per_prompt_including_framework": ratio(with_framework, prompts),
        })
    notes = list(NOTES)
    notes.append(f"Databases scanned: {scanned}; skipped (unreadable or locked): {skipped}.")
    return {"weeks": out, "databases_scanned": scanned, "databases_skipped": skipped, "notes": notes}
