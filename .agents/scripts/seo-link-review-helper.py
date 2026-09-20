#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run the offline, proposal-only SEO link-review matcher."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import seo_link_review


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True).add_parser("analyze")
    command.add_argument("--input", required=True)
    command.add_argument("--decisions", required=True, help="Offline review fixture; retained for auditable invocation")
    command.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        json.loads(Path(args.decisions).read_text(encoding="utf-8"))
        print(json.dumps(seo_link_review.analyze(json.loads(Path(args.input).read_text(encoding="utf-8"))), sort_keys=True))
        return 0
    except (OSError, ValueError, seo_link_review.ReviewError):
        print(json.dumps({"status": "blocked", "reason": "invalid_link_review_input"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
