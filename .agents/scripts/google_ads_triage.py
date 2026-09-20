#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run offline Google Ads hygiene triage against supplied snapshots only."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("google_ads_triage_helper", Path(__file__).with_name("google-ads-triage-helper.py"))
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Google Ads triage helper is unavailable")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def load(path: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("input must be a JSON object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True).add_parser("analyze")
    command.add_argument("--input", required=True)
    command.add_argument("--decisions", required=True)
    command.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(helper.analyze(load(args.input), load(args.decisions)), sort_keys=True, allow_nan=False))
    except (OSError, ValueError, json.JSONDecodeError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_decisions"}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
