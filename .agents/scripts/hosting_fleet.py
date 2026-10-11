#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Hostinger fleet inventory, onboarding plan and drift check.

Nothing here mutates hosting, GitHub, repositories or registrations. Inventory
issues GET requests (plus an optional read-only SSH multisite probe); plan and
drift compare it with repos.json and the canonical owner layout. Output files
are owner-private because they hold customer domains and account identifiers.
The API token is read from HOSTINGER_API_TOKEN and is never written or printed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_inventory import (  # noqa: E402
    FleetError,
    build_inventory,
    load_inventory,
    load_network_map,
    probe_roots,
)
from hosting_fleet_plan import CLEAN_STATES, build_plan  # noqa: E402
from hosting_fleet_remote import API_BASE, discover_networks, fetch_websites  # noqa: E402
from repo_layout_migrate import (  # noqa: E402
    MigrationError,
    atomic_write,
    expand_path,
    load_json,
    private_directory,
)

DEFAULT_STATE_DIR = "~/.aidevops/.agent-workspace/work/hostinger-fleet"
DRIFT_EXIT = 3


def write_private(path_value: str | None, payload: dict[str, Any], default_name: str) -> Path:
    """Write JSON to an explicit path or the owner-private state directory."""
    if path_value:
        destination = expand_path(path_value)
    else:
        state_dir = expand_path(DEFAULT_STATE_DIR)
        state_dir.parent.mkdir(parents=True, exist_ok=True)
        private_directory(state_dir)
        destination = state_dir / default_name
    if not destination.parent.is_dir():
        raise FleetError("Output directory does not exist")
    atomic_write(destination, json.dumps(payload, indent=2, sort_keys=True).encode() + b"\n")
    return destination


def print_plan(plan: dict[str, Any], *, all_sites: bool) -> None:
    """Print a compact human summary of plan or drift results."""
    print(f"Fleet owner: {plan['owner']}  plan_sha256: {plan['plan_sha256']}")
    print("States: " + ", ".join(f"{key}={value}" for key, value in plan["counts"].items()))
    print(f"Drift items: {plan['drift']}")
    for item in plan["sites"]:
        if not all_sites and item["state"] in CLEAN_STATES:
            continue
        where = item.get("registered_path") or item.get("expected_path") or "-"
        role = item.get("role") or "-"
        print(f"  {item['state']:<18} {item['action']:<15} {item['domain']:<45} {role:<15} {where}")
        if item.get("detail"):
            print(f"  {'':<18} {'':<15} {item['detail']}")


def load_websites(args: argparse.Namespace) -> list[dict[str, Any]]:
    """Websites from a saved API response or a live, paginated GET."""
    if args.api_response:
        payload = load_json(expand_path(args.api_response))
        websites = payload.get("data") if isinstance(payload, dict) else payload
        if not isinstance(websites, list):
            raise FleetError("API response file must contain a data array")
        return websites
    token = os.environ.get("HOSTINGER_API_TOKEN", "")
    if not token:
        raise FleetError(
            "HOSTINGER_API_TOKEN is not set; run via "
            "'aidevops secret HOSTINGER_API_TOKEN -- hostinger-helper.sh fleet inventory'"
        )
    return fetch_websites(args.api_base, token, args.username)


def network_discovery(args: argparse.Namespace, websites: list[dict[str, Any]]) -> Any:
    """Optional read-only SSH multisite probe for one hosting account."""
    if not args.discover_networks:
        return None
    if not args.ssh:
        raise FleetError("--discover-networks requires --ssh ALIAS for the hosting account")
    if len({item.get("username") for item in websites if item.get("username")}) > 1:
        raise FleetError("One SSH alias covers one account; pass --username to scope it")
    return discover_networks(args.ssh, probe_roots(websites))


def inventory_command(args: argparse.Namespace) -> int:
    """Write a normalized, content-hashed inventory."""
    websites = load_websites(args)
    discovery = network_discovery(args, websites)
    inventory = build_inventory(websites, load_network_map(args.network_map), discovery)
    destination = write_private(args.output, inventory, "inventory.json")
    print(f"Inventory: {destination}")
    print(" ".join(f"{key}={value}" for key, value in inventory["counts"].items())
          + f" accounts={len(inventory['accounts'])}"
          + f" network_discovery={inventory['network_discovery']}")
    print(f"inventory_sha256: {inventory['inventory_sha256']}")
    return 0


def plan_from_args(args: argparse.Namespace) -> dict[str, Any]:
    """Build a plan from the selected inventory and CLI options."""
    inventory = load_inventory(expand_path(args.inventory or f"{DEFAULT_STATE_DIR}/inventory.json"))
    return build_plan(inventory, vars(args))


def plan_command(args: argparse.Namespace) -> int:
    """Write a content-hashed onboarding plan."""
    plan = plan_from_args(args)
    destination = write_private(args.output, plan, "plan.json")
    print(f"Plan: {destination}")
    print_plan(plan, all_sites=args.all)
    return 0


def drift_command(args: argparse.Namespace) -> int:
    """Report drift between hosting, registrations and canonical layout."""
    plan = plan_from_args(args)
    if args.json:
        print(json.dumps(plan, indent=2, sort_keys=True))
    else:
        print_plan(plan, all_sites=args.all)
    return DRIFT_EXIT if args.fail_on_drift and plan["drift"] else 0


def add_plan_arguments(parser: argparse.ArgumentParser) -> None:
    """Arguments shared by plan and drift."""
    parser.add_argument("--inventory", help="Inventory JSON (default: private state dir)")
    parser.add_argument("--owner", required=True, help="GitHub owner for fleet repositories")
    parser.add_argument("--owner-exception", action="append", metavar="DOMAIN=OWNER",
                        help="Repository owner exception for one site (repeatable)")
    parser.add_argument("--ignore", action="append", metavar="DOMAIN",
                        help="Exclude one domain from this fleet (repeatable)")
    parser.add_argument("--host", default="github.com")
    parser.add_argument("--workspace", default="~/Git")
    parser.add_argument("--repos-json", default="~/.config/aidevops/repos.json")
    parser.add_argument("--discovery-lib", required=True)
    parser.add_argument("--all", action="store_true", help="Also list sites without drift")


def build_parser() -> argparse.ArgumentParser:
    """Command-line interface."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inventory = commands.add_parser("inventory")
    inventory.add_argument("--output")
    inventory.add_argument("--username", help="Limit to one hosting account username")
    inventory.add_argument("--network-map", help="JSON object: blog domain -> primary domain")
    inventory.add_argument("--discover-networks", action="store_true",
                           help="Read-only SSH 'wp site list' probe of document roots")
    inventory.add_argument("--ssh", metavar="ALIAS", help="SSH Host alias for the account")
    inventory.add_argument("--api-response", help="Use a saved websites response (offline)")
    inventory.add_argument("--api-base", default=API_BASE)
    inventory.set_defaults(handler=inventory_command)
    plan = commands.add_parser("plan")
    add_plan_arguments(plan)
    plan.add_argument("--output")
    plan.set_defaults(handler=plan_command)
    drift = commands.add_parser("drift")
    add_plan_arguments(drift)
    drift.add_argument("--json", action="store_true")
    drift.add_argument("--fail-on-drift", action="store_true",
                       help=f"Exit {DRIFT_EXIT} when any drift is found")
    drift.set_defaults(handler=drift_command)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except (FleetError, MigrationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
