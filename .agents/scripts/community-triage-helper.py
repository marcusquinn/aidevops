#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Produce offline community-triage queue proposals; never posts or moderates."""

from __future__ import annotations

import argparse
import json
import sys

import community_triage


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True).add_parser("analyze")
    command.add_argument("--input", required=True)
    command.add_argument("--decisions", required=True)
    command.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(community_triage.analyze(args.input, args.decisions), sort_keys=True))
    except (OSError, TypeError, community_triage.TriageError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_or_decisions"}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
