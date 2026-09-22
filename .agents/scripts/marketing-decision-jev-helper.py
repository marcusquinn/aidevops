#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Opt-in Jev adapter; dry runs are offline and live transport is explicitly gated."""

from __future__ import annotations

import argparse
import json
import os
import re

import marketing_decisions as contract
import marketing_decision_jev as jev


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True).add_parser("decide")
    command.add_argument("--input", required=True)
    command.add_argument("--dry-run", action="store_true")
    command.add_argument("--live", action="store_true")
    command.add_argument("--provider-authorized", action="store_true")
    command.add_argument("--data-authorized", action="store_true")
    command.add_argument("--key-env", default="TYPESAFE_API_KEY")
    command.add_argument("--store", help="Explicit absolute private report directory")
    args = parser.parse_args(argv)
    try:
        request = contract.validate_input(contract.load_json(args.input))
        if args.dry_run:
            result = {"status": "dry_run", "rows": sum(len(batch["rows"]) for batch in request.document["batches"]), "network": "not_attempted"}
        elif request.document["data_classification"] == "confidential":
            result = {"status": "fallback_required", "reason": "privacy_block", "fallback_ran": False}
        elif not args.live or not args.provider_authorized or not args.data_authorized:
            result = {"status": "fallback_required", "reason": "authorization_required", "fallback_ran": False}
        elif not re.fullmatch(r"TYPESAFE_API_KEY(?:_[A-Z0-9_]+)?", args.key_env):
            result = {"status": "fallback_required", "reason": "invalid_key_reference", "fallback_ran": False}
        else:
            result = jev.decide(request, os.environ.get(args.key_env))
            if result["status"] == "complete" and args.store:
                contract.store_report(args.store, request, result["report"])
    except (OSError, TypeError, contract.DecisionError):
        result = {"status": "fallback_required", "reason": "invalid_input", "fallback_ran": False}
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return 0 if result["status"] in {"dry_run", "complete"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
