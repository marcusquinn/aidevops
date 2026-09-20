#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run a bounded, read-only prospecting scan from an authorized input file."""

from __future__ import annotations

import argparse
import json

from prospecting_scan import CollectorError, ScanError, load_input, scan


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("scan", "status", "resume"))
    parser.add_argument("--input", required=True, help="authorized scan JSON")
    parser.add_argument("--dry-run", action="store_true", help="validate without provider or store writes")
    args = parser.parse_args()
    if args.command != "scan":
        parser.error("status and resume require the project-backed live runner")
    if not args.dry_run:
        parser.error("live mode requires an explicit project-backed runner")
    try:
        result = scan(load_input(args.input))
    except (CollectorError, ScanError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
