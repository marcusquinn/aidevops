#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run bounded, offline intent-to-page matching."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import intent_page_matching as matching


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("match")
    command.add_argument("--input", required=True, help="page evidence JSON")
    command.add_argument("--decisions", required=True, help="query evidence JSON")
    command.add_argument("--dry-run", action="store_true", help="required: output only, never mutate")
    args = parser.parse_args(argv)
    if not args.dry_run:
        parser.error("--dry-run is required; this helper never writes page changes")
    try:
        report = matching.match(json.loads(Path(args.input).read_text()), json.loads(Path(args.decisions).read_text()))
    except (OSError, json.JSONDecodeError, matching.MatchError) as error:
        print(json.dumps({"status": "failed", "reason": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
