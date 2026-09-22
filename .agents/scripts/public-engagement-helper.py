#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Public-engagement planning CLI. Defaults to dry-run and never calls a provider."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from public_engagement import plan, receipt_outcome


def document(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("input must be a regular JSON file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("input must be a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "draft", "inspect", "pause"):
        command = commands.add_parser(name)
        command.add_argument("--input", type=Path, required=True)
        command.add_argument("--dry-run", action="store_true")
    receipt = commands.add_parser("receipt")
    receipt.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    try:
        value = document(args.input)
        if args.command == "receipt":
            result = receipt_outcome(value)
        elif args.command == "pause":
            result = {"state": "paused", "mutated": False, "reason": "owner route required for grant mutation"}
        else:
            result = plan(value)
        result["dry_run"] = bool(getattr(args, "dry_run", False))
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
