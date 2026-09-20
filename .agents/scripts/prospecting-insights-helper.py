#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Produce offline prospecting insight snapshots; never contacts or profiles people."""

from __future__ import annotations

import argparse
import json

import prospecting_insights


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    derive = commands.add_parser("derive")
    derive.add_argument("--input", required=True)
    derive.add_argument("--decisions", required=True)
    derive.add_argument("--dry-run", action="store_true", required=True)
    compare = commands.add_parser("compare")
    compare.add_argument("--baseline", required=True)
    compare.add_argument("--current", required=True)
    compare.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        report = prospecting_insights.derive(args.input, args.decisions) if args.command == "derive" else prospecting_insights.compare(args.baseline, args.current)
        print(json.dumps(report, sort_keys=True))
    except (OSError, TypeError, prospecting_insights.InsightError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_or_decisions"}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
