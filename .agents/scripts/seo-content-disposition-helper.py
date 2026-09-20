#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""CLI wrapper for offline content disposition proposals."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from seo_content_disposition import DispositionError, review


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["review"])
    parser.add_argument("--input", required=True)
    parser.add_argument("--decisions", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.dry_run:
        parser.error("review is proposal-only; pass --dry-run")
    try:
        report = review(json.loads(Path(args.input).read_text()), json.loads(Path(args.decisions).read_text()))
    except (DispositionError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
