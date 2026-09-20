#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Collect opt-in, read-only Google Ads or Meta account snapshots."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import date
from pathlib import Path

from marketing_account_google import GoogleAccountError, collect as collect_google
from marketing_account_meta import MetaAccountError, collect as collect_meta

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _date(value: str) -> str:
    if not DATE.fullmatch(value):
        raise ValueError("dates must use YYYY-MM-DD")
    date.fromisoformat(value)
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    collect = commands.add_parser("collect")
    collect.add_argument("--provider", choices=("google-ads", "meta"), required=True)
    collect.add_argument("--account-ref", required=True)
    collect.add_argument("--from", dest="start", type=_date, required=True)
    collect.add_argument("--to", dest="end", type=_date, required=True)
    collect.add_argument("--dry-run", action="store_true")
    collect.add_argument("--live", action="store_true", help="Permit the fixed read-only provider request")
    collect.add_argument("--output", help="New absolute private snapshot path")
    args = parser.parse_args(argv)
    if args.start > args.end:
        parser.error("--from must not be after --to")
    plan = {"schema": "aidevops.marketing-account-snapshot/v1", "provider": args.provider,
            "account_ref": args.account_ref, "date_start": args.start, "date_end": args.end,
            "network_calls": 0 if args.dry_run or not args.live else 1, "read_only": True}
    if args.dry_run or not args.live:
        print(json.dumps(plan, sort_keys=True))
        return 0
    try:
        result = collect_google(args.account_ref, args.start, args.end, os.environ.get("GOOGLE_ADS_ACCESS_TOKEN", ""), os.environ.get("GOOGLE_ADS_DEVELOPER_TOKEN", "")) if args.provider == "google-ads" else collect_meta(args.account_ref, args.start, args.end, os.environ.get("META_ACCESS_TOKEN", ""))
        result.update(plan)
        payload = json.dumps(result, sort_keys=True) + "\n"
        if not args.output:
            raise ValueError("--output is required for live collection")
        output = Path(args.output)
        if not output.is_absolute() or output.exists() or output.is_symlink():
            raise ValueError("output must be a new absolute regular path")
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.write_text(payload, encoding="utf-8")
        os.chmod(output, 0o600)
        print(json.dumps({"provider": args.provider, "records": len(result["records"]), "written": True}))
        return 0
    except (GoogleAccountError, MetaAccountError, OSError, ValueError) as error:
        print(f"marketing-account-snapshot: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
