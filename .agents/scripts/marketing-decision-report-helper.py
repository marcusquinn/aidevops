#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Render fail-closed aggregate marketing decision reports and holdout evaluations."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from marketing_decision_reports import DecisionReportError, build_report, evaluate_holdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("report", "evaluate"):
        command = commands.add_parser(name)
        command.add_argument("--input", required=True)
        command.add_argument("--output")
        command.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        input_data = json.loads(Path(args.input).read_text(encoding="utf-8"))
        result = build_report(input_data) if args.command == "report" else evaluate_holdout(input_data)
        if args.output and not args.dry_run:
            Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, TypeError, ValueError, json.JSONDecodeError, DecisionReportError) as exc:
        print(f"marketing-decision-report: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
