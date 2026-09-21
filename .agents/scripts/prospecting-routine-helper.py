#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local, disabled-by-default prospecting routine planner and digest preview."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import prospecting_alerts
import prospecting_jobs


def load(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ValueError("input must be a regular JSON file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("input must be an object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run-due", "digest-preview", "usage"):
        command = commands.add_parser(name)
        command.add_argument("--input", required=True, type=Path)
        command.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        document = load(args.input)
        report = prospecting_jobs.plan(document)
        if args.command == "digest-preview":
            rows = prospecting_alerts.digest(document.get("leads", []), set(document.get("delivered", [])), set(document.get("hidden", [])))
            report = {"project_id": report["project_id"], "send": bool(rows), "leads": rows}
        elif args.command == "usage":
            report = {"project_id": report["project_id"], "jobs": [{"id": job["id"], "budget": job["budget"]} for job in report["jobs"]]}
        print(json.dumps(report, sort_keys=True))
    except (ValueError, prospecting_jobs.RoutineError, prospecting_alerts.AlertError, json.JSONDecodeError) as error:
        print(f"prospecting routines: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
