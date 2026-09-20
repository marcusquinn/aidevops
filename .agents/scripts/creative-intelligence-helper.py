#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""CLI for the offline creative intelligence snapshot analyzer."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import creative_intelligence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True)
    analyze = command.add_parser("analyze")
    analyze.add_argument("--input", required=True)
    analyze.add_argument("--decisions", required=True)
    analyze.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        manifest = json.loads(Path(args.input).read_text(encoding="utf-8"))
        decisions = json.loads(Path(args.decisions).read_text(encoding="utf-8"))
        if not isinstance(manifest.get("assets"), list) or not isinstance(decisions.get("labels", {}), dict):
            raise ValueError("snapshot requires assets and decisions requires labels")
        print(json.dumps(creative_intelligence.analyze(manifest, decisions), sort_keys=True))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "failed", "reason": str(error)}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
