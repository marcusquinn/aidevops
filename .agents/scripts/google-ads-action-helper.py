#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""CLI for approval-bound Google Ads account actions (plan, apply, rollback).

Credentials come only from the environment: GOOGLE_ADS_ACCESS_TOKEN (required)
and GOOGLE_ADS_DEVELOPER_TOKEN (optional; sunset by Google on 2026-09-09).
Apply and rollback need a fresh `sudo aidevops approve marketing-plan` record.
"""

from __future__ import annotations

import argparse
import json
import sys

import google_ads_actions as ads
import marketing_action_io as action_io


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = root.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="read live state, validate-only mutate, write a reviewable plan")
    plan.add_argument("--input", required=True)
    plan.add_argument("--config", required=True)
    plan.add_argument("--output", required=True, help="new file; never overwritten")
    apply = commands.add_parser("apply", help="apply an operator-approved plan")
    apply.add_argument("--plan", required=True)
    apply.add_argument("--receipt-dir", required=True)
    rollback = commands.add_parser("rollback", help="revert an applied receipt")
    rollback.add_argument("--receipt", required=True)
    return root


def _run(arguments: argparse.Namespace) -> dict:
    if arguments.command == "plan":
        proposal = action_io.load_json(arguments.input)
        login = proposal.get("login_customer_id", "") if isinstance(proposal, dict) else ""
        plan = ads.build_plan(proposal, action_io.load_json(arguments.config), ads.client_from_environment(login))
        path = ads.write_plan(arguments.output, plan)
        return {"status": "planned", "plan": str(path), "plan_digest": plan["plan_digest"],
                "expires_at": plan["expires_at"], "actions": [item["summary"] for item in plan["actions"]],
                "next": f"operator runs: sudo aidevops approve marketing-plan {path}"}
    if arguments.command == "apply":
        plan = ads.validate_plan(action_io.load_json(arguments.plan))
        receipt, replayed = ads.apply_plan(plan, arguments.receipt_dir, ads.client_from_environment(
            plan["login_customer_id"]))
        return {"receipt": receipt, "replayed": replayed}
    receipt = action_io.load_json(arguments.receipt)
    login = receipt.get("login_customer_id", "") if isinstance(receipt, dict) else ""
    rolled_back, replayed = ads.rollback_receipt(arguments.receipt, ads.client_from_environment(login))
    return {"receipt": rolled_back, "replayed": replayed}


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        result = _run(arguments)
    except (ads.GoogleAdsActionError, action_io.ActionError, OSError, ValueError) as error:
        print(json.dumps({"status": "denied", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
