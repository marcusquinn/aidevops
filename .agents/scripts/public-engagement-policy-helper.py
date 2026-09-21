#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Inspect public-engagement policy files; lifecycle mutations require owner identity."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from _public_engagement_policy import PolicyError, preview


def _document(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise PolicyError("policy input must be a regular file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise PolicyError("policy input must be an object")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect")
    preview_command = commands.add_parser("preview")
    for command in (inspect, preview_command):
        command.add_argument("--input", type=Path, required=True)
        command.add_argument("--now-epoch", type=int)
    preview_command.add_argument("--dry-run", action="store_true", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = preview(_document(args.input), args.now_epoch if args.now_epoch is not None else int(time.time()))
        result["dry_run"] = args.command == "preview"
        result["mutated"] = False
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, json.JSONDecodeError, PolicyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
