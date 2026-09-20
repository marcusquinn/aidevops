#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate or run bounded offline marketing decision batches."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marketing_decisions as contract


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="Validate one decision input")
    validate.add_argument("--input", required=True)
    run = commands.add_parser("run", help="Run with explicitly supplied offline decisions")
    run.add_argument("--input", required=True)
    run.add_argument("--decisions", required=True)
    run.add_argument("--dry-run", action="store_true", required=True)
    run.add_argument("--store", help="Explicit absolute private artifact directory")
    return parser


def execute(args: argparse.Namespace) -> dict[str, object]:
    request = contract.validate_input(contract.load_json(args.input))
    if args.command == "validate":
        return {
            "status": "valid",
            "schema": contract.INPUT_SCHEMA,
            "input_digest": request.input_digest,
            "cache_key": request.cache_key,
            "rows": sum(len(batch["rows"]) for batch in request.document["batches"]),
        }
    supplied = contract.validate_supplied(contract.load_json(args.decisions), request)
    report = contract.run(request, supplied)
    contract.validate_report(report, request)
    if args.store:
        path, replayed = contract.store_report(Path(args.store), request, report)
        report["artifact"] = {"path": str(path), "replayed": replayed}
    return report


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        print(json.dumps(execute(args), sort_keys=True, allow_nan=False))
        return 0
    except (OSError, TypeError, contract.DecisionError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_decisions_or_storage"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
