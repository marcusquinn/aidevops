#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""CLI for reviewable local marketing action plans, application, and rollback."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import marketing_actions as actions


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="render an exact non-mutating plan")
    plan.add_argument("--input", required=True)
    plan.add_argument("--dry-run", action="store_true", required=True)
    apply = commands.add_parser("apply", help="apply a runtime-approved exact plan")
    apply.add_argument("--plan", required=True)
    apply.add_argument("--receipt-dir", required=True)
    rollback = commands.add_parser("rollback", help="rollback an exact applied receipt")
    rollback.add_argument("--receipt", required=True)
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "plan":
            result = actions.build_plan(actions.load_json(arguments.input))
        elif arguments.command == "apply":
            plan = actions.validate_plan(actions.load_json(arguments.plan))
            receipt, replayed = actions.apply_plan(plan, arguments.receipt_dir)
            result = {"receipt": receipt, "replayed": replayed}
        else:
            receipt_path = Path(arguments.receipt)
            receipt, replayed = actions.rollback_receipt(actions.load_json(receipt_path), receipt_path)
            result = {"receipt": receipt, "replayed": replayed}
    except (actions.ActionError, OSError, ValueError) as error:
        print(json.dumps({"status": "denied", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
