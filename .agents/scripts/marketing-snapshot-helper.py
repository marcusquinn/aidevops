#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Import offline marketing and site snapshots without network access."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from marketing_snapshot_imports import ImportError, SUPPORTED_KINDS, normalize


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    importer = commands.add_parser("import")
    importer.add_argument("--kind", choices=sorted(SUPPORTED_KINDS), required=True)
    importer.add_argument("--input", required=True)
    importer.add_argument("--dry-run", action="store_true")
    importer.add_argument("--output", help="Explicit private output path")
    importer.add_argument("--scope", help="Opaque account or site scope retained with the evidence")
    importer.add_argument("--date-start", help="Source reporting window start, retained verbatim")
    importer.add_argument("--date-end", help="Source reporting window end, retained verbatim")
    importer.add_argument("--timezone", help="Source reporting timezone, retained verbatim")
    importer.add_argument("--currency", help="Source ISO currency, retained verbatim")
    args = parser.parse_args(argv)
    try:
        report = normalize(args.kind, args.input, {
            "scope": args.scope, "date_start": args.date_start, "date_end": args.date_end,
            "timezone": args.timezone, "currency": args.currency,
        })
        payload = json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n"
        if args.output and not args.dry_run:
            output = Path(args.output)
            if not output.is_absolute() or output.exists() or output.is_symlink():
                raise ImportError("output must be a new absolute regular path")
            output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            descriptor = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(payload)
        print(payload, end="")
        return 0
    except (ImportError, OSError) as error:
        print(f"marketing-snapshot: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
