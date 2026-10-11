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
from hosting_fleet_plan import (  # noqa: E402
    CLEAN_STATES, build_plan,
)
from hosting_fleet_privacy import config_pairs, fleet_entities, merge_private_entities  # noqa: E402
from hosting_fleet_move import run_move  # noqa: E402
from hosting_fleet_provision import (  # noqa: E402
    assert_plan_current,
    build_provision,
    load_reviewed_plan,
    print_provision,
)
from hosting_fleet_ready import build_readiness, print_readiness  # noqa: E402
from hosting_fleet_remote import API_BASE, discover_networks, fetch_websites  # noqa: E402
from repo_layout_migrate import (  # noqa: E402
    MigrationError,
    atomic_write,
    expand_path,
    load_json,
    private_directory,
)

DEFAULT_STATE_DIR = "~/.aidevops/.agent-workspace/work/hostinger-fleet"
DEFAULT_CONFIG = "~/.config/aidevops/hosting-fleet.json"
DRIFT_EXIT = 3
NOT_READY_EXIT = 4
PROVISION_FAILED_EXIT = 5


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
        if item.get("served_by"):
            print(f"  {'':<18} {'':<15} served by repository {item['expected_slug']}")
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
    sync_privacy(inventory, args.config)
    return 0


def load_fleet_config(path_value: str) -> dict[str, Any]:
    """Optional owner-private fleet config; absent means no stored defaults."""
    path = expand_path(path_value)
    if not path.exists() and not path.is_symlink():
        return {}
    details = path.lstat()
    if path.is_symlink() or not path.is_file() or details.st_uid != os.getuid() \
            or details.st_mode & 0o077:
        raise FleetError(f"Fleet config must be an owner-private (0600) regular file: {path}")
    config = load_json(path)
    if not isinstance(config, dict):
        raise FleetError("Fleet config must be a JSON object")
    return config


def sync_privacy(inventory: dict[str, Any], config_path: str) -> None:
    """Update the local guard, reporting counts only even on failure."""
    try:
        entities = fleet_entities(inventory, load_fleet_config(config_path))
        added = merge_private_entities(entities)
    except (FleetError, MigrationError, OSError, ValueError, KeyError, TypeError) as exc:
        raise FleetError("Privacy sync failed; check private inventory, config and entity file") from exc
    print(f"Privacy sync: selected={len(entities)} added={added}")


def privacy_sync_command(args: argparse.Namespace) -> int:
    """Sync a previously saved inventory without hosting or GitHub requests."""
    try:
        inventory = load_inventory(expand_path(args.inventory))
    except (FleetError, MigrationError, OSError, ValueError) as exc:
        raise FleetError("Privacy sync failed; check private inventory") from exc
    sync_privacy(inventory, args.config)
    return 0


def merged_options(args: argparse.Namespace) -> dict[str, Any]:
    """CLI options layered over the private fleet config (CLI wins for owner)."""
    config = load_fleet_config(args.config)
    options = vars(args).copy()
    options["owner"] = args.owner or config.get("owner")
    if not options["owner"]:
        raise FleetError("Pass --owner or set \"owner\" in the fleet config")
    options["owner_exception"] = config_pairs(config, "owner_exceptions") + (args.owner_exception or [])
    options["site_repo"] = config_pairs(config, "site_repos") + (args.site_repo or [])
    ignored = config.get("ignore") or []
    if not isinstance(ignored, list):
        raise FleetError("Fleet config 'ignore' must be a list")
    options["ignore"] = [str(item) for item in ignored] + (args.ignore or [])
    return options


def plan_from_args(args: argparse.Namespace) -> dict[str, Any]:
    """Build a plan from the selected inventory, fleet config and CLI options."""
    inventory = load_inventory(expand_path(args.inventory or f"{DEFAULT_STATE_DIR}/inventory.json"))
    return build_plan(inventory, merged_options(args))


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


def ready_command(args: argparse.Namespace) -> int:
    """Read-only configured readiness of every fleet repository, with a private receipt."""
    plan = plan_from_args(args)
    receipt = build_readiness(plan, args.repos_json, evidence=args.worker_evidence)
    destination = write_private(args.output, receipt, "readiness.json")
    if args.json:
        print(json.dumps(receipt, indent=2, sort_keys=True))
    else:
        print_readiness(receipt, all_repos=args.all)
        print(f"Receipt: {destination}  readiness_sha256: {receipt['readiness_sha256']}")
    return NOT_READY_EXIT if args.fail_on_not_ready and not receipt["all_ready"] else 0


def provision_command(args: argparse.Namespace) -> int:
    """Preview, or apply against the exact reviewed plan hash."""
    if args.apply and not args.plan_sha256:
        raise FleetError("--apply requires --plan-sha256 of the reviewed plan")
    plan_path = expand_path(args.plan)
    plan = load_reviewed_plan(plan_path, args.plan_sha256)
    if args.apply:
        assert_plan_current(plan_path, plan, load_fleet_config(args.config))
    report = build_provision(plan, {"apply": args.apply, "site": args.site,
                                    "repos_json": args.repos_json, "state_dir": DEFAULT_STATE_DIR})
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_provision(report)
    return PROVISION_FAILED_EXIT if report["counts"].get("failed") else 0


def move_command(args: argparse.Namespace) -> int:
    """Preview a scoped native layout plan, or apply one with automation snapshot/restore."""
    return run_move(args, lambda: plan_from_args(args), expand_path(DEFAULT_STATE_DIR))


def add_plan_arguments(parser: argparse.ArgumentParser) -> None:
    """Arguments shared by plan and drift."""
    parser.add_argument("--inventory", help="Inventory JSON (default: private state dir)")
    parser.add_argument("--config", default=DEFAULT_CONFIG,
                        help="Owner-private fleet config JSON (owner, owner_exceptions, "
                             "site_repos, ignore); flags add to it")
    parser.add_argument("--owner", help="GitHub owner for fleet repositories (or config owner)")
    parser.add_argument("--owner-exception", action="append", metavar="DOMAIN=OWNER",
                        help="Repository owner exception for one site (repeatable)")
    parser.add_argument("--site-repo", action="append", metavar="HOSTED_DOMAIN=REPO",
                        help="Hosted site served by a differently named repository, e.g. a "
                             "pre-launch subdomain (repeatable)")
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
    inventory.add_argument("--config", default=DEFAULT_CONFIG,
                           help="Private fleet config for the automatic privacy sync")
    inventory.add_argument("--username", help="Limit to one hosting account username")
    inventory.add_argument("--network-map", help="JSON object: blog domain -> primary domain")
    inventory.add_argument("--discover-networks", action="store_true",
                           help="Read-only SSH 'wp site list' probe of document roots")
    inventory.add_argument("--ssh", metavar="ALIAS", help="SSH Host alias for the account")
    inventory.add_argument("--api-response", help="Use a saved websites response (offline)")
    inventory.add_argument("--api-base", default=API_BASE)
    inventory.set_defaults(handler=inventory_command)
    privacy = commands.add_parser("privacy-sync", help="Sync fleet names to the local privacy guard")
    privacy.add_argument("--inventory", default=f"{DEFAULT_STATE_DIR}/inventory.json")
    privacy.add_argument("--config", default=DEFAULT_CONFIG)
    privacy.set_defaults(handler=privacy_sync_command)
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
    ready = commands.add_parser("ready", help="Read-only configured readiness per repository")
    add_plan_arguments(ready)
    ready.add_argument("--output", help="Receipt path (default: private state dir)")
    ready.add_argument("--json", action="store_true")
    ready.add_argument("--worker-evidence", action="store_true",
                       help="Also report each repo's latest merged worker PR (evidence only)")
    ready.add_argument("--fail-on-not-ready", action="store_true",
                       help=f"Exit {NOT_READY_EXIT} unless every repository is ready")
    ready.set_defaults(handler=ready_command)
    provision = commands.add_parser("provision", help="Create/adopt, clone, init and deliver from a reviewed plan")
    provision.add_argument("--plan", default=f"{DEFAULT_STATE_DIR}/plan.json")
    provision.add_argument("--site", action="append", metavar="DOMAIN",
                           help="Limit to one planned site (repeatable)")
    provision.add_argument("--apply", action="store_true", help="Execute; requires --plan-sha256")
    provision.add_argument("--plan-sha256", help="Exact hash of the reviewed plan")
    provision.add_argument("--repos-json", default="~/.config/aidevops/repos.json")
    provision.add_argument("--config", default=DEFAULT_CONFIG,
                           help="Fleet config; apply refuses plans that predate its owner/ignore list")
    provision.add_argument("--json", action="store_true")
    provision.set_defaults(handler=provision_command)
    move = commands.add_parser("move", help="Move named misplaced sites with automation snapshot/restore")
    add_plan_arguments(move)
    move.add_argument("--site", action="append", metavar="DOMAIN", help="Misplaced site to move (repeatable)")
    move.add_argument("--apply", action="store_true",
                      help="Snapshot, pause, native plan + apply, restore; requires --confirm")
    move.add_argument("--confirm", help="Exact fleet plan_sha256 printed by the preview")
    move.add_argument("--restore", metavar="SNAPSHOT",
                      help="Restore automation from a paused move snapshot once moves are complete")
    move.add_argument("--json", action="store_true")
    move.set_defaults(handler=move_command)
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
