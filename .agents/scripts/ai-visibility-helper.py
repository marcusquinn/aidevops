#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Import and analyse supplied AI visibility captures without live collection."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ai_visibility


def load(path: str) -> object:
    with Path(path).open(encoding="utf-8") as stream:
        return json.load(stream)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("import", "analyze"):
        command = commands.add_parser(name, help=f"{name} supplied captures")
        command.add_argument("--input", required=True)
        command.add_argument("--dry-run", action="store_true", required=True)
        if name == "analyze":
            command.add_argument("--decisions", required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        document = load(args.input)
        if args.command == "import":
            captures = [ai_visibility.normalize_capture(item) for item in document["captures"]]
            output = {"schema": "aidevops.ai-visibility-import/v1", "collection": "imported_captures_only", "captures": captures}
        else:
            output = ai_visibility.analyze(document, load(args.decisions))
        print(json.dumps(output, sort_keys=True, allow_nan=False))
        return 0
    except (OSError, TypeError, ValueError, json.JSONDecodeError, KeyError):
        print(json.dumps({"status": "blocked", "reason": "invalid_visibility_capture_or_decisions"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
