#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""CLI for the non-secret credential registry (GH#34680).

Normally invoked through `aidevops secret <command>` (secret-helper.sh).
Never reads, prints or stores secret values.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess  # nosec B404 -- fixed argv to the repository-owned secret-helper.sh, never a shell
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import credential_inventory_fields as rules  # noqa: E402
import credential_inventory_names as names  # noqa: E402
import credential_inventory_store as store  # noqa: E402

EXIT_INVALID = 2
EXIT_DEFAULT_NONE = 3
EXIT_DEFAULT_UNDECLARED = 4


def emit_json(payload: Any) -> None:
    """Print deterministic JSON."""
    print(json.dumps(payload, indent=2, sort_keys=True))


def stored_secret_names() -> list[str] | None:
    """Names-only listing from secret-helper.sh inventory; None if unavailable."""
    helper = SCRIPT_DIR / "secret-helper.sh"
    bash = shutil.which("bash")
    if not bash:
        return None
    try:
        # Absolute bash, repository-owned helper, fixed argv, no shell.
        result = subprocess.run(  # nosec B603
            [bash, str(helper), "inventory"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        if result.returncode != 0:
            return None
        return sorted(item["name"] for item in json.loads(result.stdout).get("secrets", []))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


# --------------------------------------------------------------------------
# describe
# --------------------------------------------------------------------------


def summary(data: dict[str, Any], stored: list[str] | None) -> dict[str, Any]:
    """Whole-registry view, grouped by provider, with undescribed secrets."""
    providers: dict[str, dict[str, Any]] = {}
    for name in sorted(data["credentials"]):
        record = names.describe(data, name)
        group = providers.setdefault(record["provider"], {"credentials": []})
        group["credentials"].append(record)
    for provider, group in providers.items():
        status, default = names.resolve_default(data, provider)
        group["default"] = {"status": status, "name": default}
    known = set(data["credentials"])
    for record in data["credentials"].values():
        known.update(record.get("aliases") or [])
    result: dict[str, Any] = {"providers": providers, "provider_accounts": data["provider_accounts"]}
    if stored is None:
        result["undescribed"] = None
        result["stored_listing"] = "unavailable"
    else:
        result["undescribed"] = [name for name in stored if name not in known]
    return result


def format_account(account: dict[str, Any] | None) -> str:
    """Short human label for an account record."""
    if not account:
        return "account: unrecorded"
    ownership = account.get("ownership") or {}
    tags = [ownership.get("type") or "ownership unknown"]
    if ownership:
        tags.append("confirmed" if ownership.get("confirmed") else "unconfirmed")
    return f"account: {account.get('name')} ({', '.join(tags)})"


def format_record(record: dict[str, Any]) -> str:
    """One human-readable line for a credential."""
    reach = record.get("reach") or {}
    parts = [
        record["name"] + ("  [default]" if record.get("is_default") else ""),
        format_account(record.get("account")),
        "reach: " + (", ".join(reach.get("zones", []) + reach.get("resources", [])) or "unrecorded"),
        "expires: " + (record.get("expires_at") or "unrecorded"),
    ]
    if record.get("purpose"):
        parts.append("purpose: " + record["purpose"])
    if record.get("aliases"):
        parts.append("aliases: " + ", ".join(record["aliases"]))
    return "  " + "\n      ".join(parts)


def print_summary(view: dict[str, Any]) -> None:
    """Text rendering of the whole registry."""
    labels = {"set": "{name}", "none": "explicitly none", "undeclared": "undeclared"}
    if not view["providers"]:
        print("No credentials described yet. Record one with: aidevops secret record NAME --provider PROVIDER --account REF")
    for provider, group in sorted(view["providers"].items()):
        default = group["default"]
        print(f"{provider}  (default: {labels[default['status']].format(name=default['name'])})")
        for record in group["credentials"]:
            print(format_record(record))
    undescribed = view.get("undescribed")
    if undescribed:
        print(f"\nUndescribed stored secrets ({len(undescribed)}): " + ", ".join(undescribed))
        print("Describe them with: aidevops secret record NAME --provider PROVIDER --account REF")
    elif undescribed is None:
        print("\nStored-secret listing unavailable; undescribed secrets not checked.")


def cmd_describe(args: argparse.Namespace) -> int:
    data = store.load()
    if args.name:
        record = names.describe(data, args.name)
        if args.json:
            emit_json(record)
        else:
            print(format_record(record))
        return 0
    view = summary(data, stored_secret_names())
    if args.json:
        emit_json(view)
    else:
        print_summary(view)
    return 0


# --------------------------------------------------------------------------
# mutations
# --------------------------------------------------------------------------


def record_fields(args: argparse.Namespace) -> dict[str, Any]:
    """Translate CLI flags into record_credential keyword fields."""
    fields: dict[str, Any] = {
        "account_ref": args.account,
        "kind": args.kind,
        "purpose": args.purpose,
        "expires_at": args.expires,
    }
    if args.zones is not None:
        fields["zones"] = rules.split_csv(args.zones)
    if args.resources is not None:
        fields["resources"] = rules.split_csv(args.resources)
    return fields


def cmd_record(args: argparse.Namespace) -> int:
    with store.locked(write=not args.check) as data:
        record = store.record_credential(data, args.name, args.provider, **record_fields(args))
    if args.check:
        return 0
    print(f"Recorded {args.name} ({record['provider']}" + (f", account {record['account_ref']})" if record.get("account_ref") else ", account unrecorded)"))
    return 0


def cmd_account(args: argparse.Namespace) -> int:
    if args.account_command == "list":
        data = store.load()
        if args.json:
            emit_json(data["provider_accounts"])
            return 0
        for ref, account in sorted(data["provider_accounts"].items()):
            print(f"{ref}  {account['provider']}  {format_account(account)}")
        return 0
    with store.locked() as data:
        store.add_account(
            data, args.ref, args.provider, args.name,
            account_id_env=args.account_id_env, ownership_type=args.ownership_type,
            owner=args.owner, evidence=args.evidence, confirmed=args.confirmed,
        )
    print(f"Recorded account {args.ref} ({args.provider})")
    return 0


def cmd_default(args: argparse.Namespace) -> int:
    if args.name is None and not args.none:
        status, name = names.resolve_default(store.load(), args.provider)
        print({"set": name, "none": "explicitly none", "undeclared": "undeclared"}[status])
        return 0
    if args.name and args.none:
        raise rules.InventoryError("give either NAME or --none, not both")
    with store.locked() as data:
        names.set_default(data, args.provider, None if args.none else args.name)
    print(f"Default for {args.provider}: " + ("explicitly none" if args.none else args.name))
    return 0


def cmd_alias(args: argparse.Namespace) -> int:
    with store.locked() as data:
        names.add_alias(data, args.name, args.alias)
    print(f"{args.alias} is now an alias of {args.name}")
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    status, name = names.resolve_default(store.load(), args.provider)
    if status == "set":
        print(name)
        return 0
    print(f"{args.provider}: default {'explicitly none' if status == 'none' else 'undeclared'}", file=sys.stderr)
    return EXIT_DEFAULT_NONE if status == "none" else EXIT_DEFAULT_UNDECLARED


def cmd_validate(_args: argparse.Namespace) -> int:
    store.load()
    print("Credential registry is valid")
    return 0


# --------------------------------------------------------------------------
# parser
# --------------------------------------------------------------------------


def add_record_parser(sub: argparse._SubParsersAction) -> None:
    parser = sub.add_parser("record", help="record non-secret metadata for a stored secret")
    parser.add_argument("name")
    parser.add_argument("--provider", required=True)
    parser.add_argument("--account", help="provider account ref (see: account add)")
    parser.add_argument("--kind", help="e.g. api_token, api_key, access_token")
    parser.add_argument("--purpose")
    parser.add_argument("--zones", help="comma-separated zones/domains, or 'all'")
    parser.add_argument("--resources", help="comma-separated type:name resources")
    parser.add_argument("--expires", help="YYYY-MM-DD or 'never'")
    parser.add_argument("--check", action="store_true", help="validate only; write nothing")
    parser.set_defaults(func=cmd_record)


def add_account_parser(sub: argparse._SubParsersAction) -> None:
    parser = sub.add_parser("account", help="manage provider accounts")
    account_sub = parser.add_subparsers(dest="account_command", required=True)
    add = account_sub.add_parser("add")
    add.add_argument("ref")
    add.add_argument("--provider", required=True)
    add.add_argument("--name", required=True, help="human account name")
    add.add_argument("--account-id-env", help="secret NAME holding the account ID (never the ID)")
    add.add_argument("--ownership-type", choices=rules.OWNERSHIP_TYPES)
    add.add_argument("--owner")
    add.add_argument("--evidence")
    add.add_argument("--confirmed", action="store_true", default=None)
    listing = account_sub.add_parser("list")
    listing.add_argument("--json", action="store_true")
    parser.set_defaults(func=cmd_account)


def add_simple_parsers(sub: argparse._SubParsersAction) -> None:
    describe = sub.add_parser("describe", help="show what credentials open and reach")
    describe.add_argument("name", nargs="?")
    describe.add_argument("--json", action="store_true")
    describe.set_defaults(func=cmd_describe)
    default = sub.add_parser("default", help="show or declare a provider default")
    default.add_argument("provider")
    default.add_argument("name", nargs="?")
    default.add_argument("--none", action="store_true", help="declare explicitly that there is no default")
    default.set_defaults(func=cmd_default)
    alias = sub.add_parser("alias", help="declare a retired name as an alias")
    alias.add_argument("name")
    alias.add_argument("alias")
    alias.set_defaults(func=cmd_alias)
    resolve = sub.add_parser("resolve", help="print the provider default credential name")
    resolve.add_argument("provider")
    resolve.set_defaults(func=cmd_resolve)
    validate = sub.add_parser("validate", help="validate the registry file")
    validate.set_defaults(func=cmd_validate)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aidevops secret", description="Non-secret credential registry")
    sub = parser.add_subparsers(dest="command", required=True)
    add_simple_parsers(sub)
    add_record_parser(sub)
    add_account_parser(sub)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except rules.InventoryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_INVALID


if __name__ == "__main__":
    sys.exit(main())
