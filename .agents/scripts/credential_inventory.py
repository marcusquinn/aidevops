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
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import credential_inventory_fields as rules  # noqa: E402
import credential_inventory_names as names  # noqa: E402
import credential_inventory_store as store  # noqa: E402
import credential_inventory_view as view  # noqa: E402

EXIT_INVALID = 2
EXIT_DEFAULT_NONE = 3
EXIT_DEFAULT_UNDECLARED = 4


def emit_json(payload: Any) -> None:
    """Print deterministic JSON."""
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_describe(args: argparse.Namespace) -> int:
    data = store.load()
    if args.name:
        record = names.describe(data, args.name)
        if args.json:
            emit_json(record)
        else:
            print(view.format_record(record))
        return 0
    summary = view.summary(data, view.stored_secret_names())
    if args.json:
        emit_json(summary)
    else:
        view.print_summary(summary)
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
        record.pop("draft", None)  # an explicit record confirms an organise draft (GH#34723)
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


def cmd_injection_map(args: argparse.Namespace) -> int:
    """Print tab-separated REQUESTED SOURCE name pairs (names only, never values)."""
    for requested, source in names.injection_map(store.load(), args.names or None):
        print(f"{requested}\t{source}")
    return 0


def cmd_resolve_name(args: argparse.Namespace) -> int:
    """Print the source credential for an alias/conventional default; exit 1 if none."""
    source = names.resolve_name(store.load(), args.name)
    if source is None:
        return 1
    print(source)
    return 0


def cmd_validate(_args: argparse.Namespace) -> int:
    store.load()
    print("Credential registry is valid")
    return 0


def cmd_dependents(args: argparse.Namespace) -> int:
    """Local, read-only search for what uses a credential (GH#34719)."""
    import credential_inventory_dependents as dependents

    result = dependents.find_dependents(names.related_names(store.load(), args.name))
    if args.json:
        emit_json(result)
    else:
        print(dependents.render(result))
    return 0


def cmd_drift(args: argparse.Namespace) -> int:
    """Offline drift report from the registry and cached verifications (GH#34722)."""
    import credential_inventory_drift as drift

    report = drift.drift(store.load(), view.stored_secret_names())
    if args.json:
        emit_json(report)
    else:
        print(drift.render_drift(report))
    return 0


def cmd_owner(args: argparse.Namespace) -> int:
    """Which account/credentials hold a zone or resource; never guesses."""
    import credential_inventory_owner as ownership

    result = ownership.owner(store.load(), args.resource)
    if args.json:
        emit_json(result)
    else:
        print(ownership.render_owner(result))
    return 0 if result["status"] != "unknown" else 1


def cmd_organise(args: argparse.Namespace) -> int:
    """Plan-first cleanup proposals; --apply-drafts writes unconfirmed drafts only (GH#34723)."""
    import credential_inventory_organise as organise
    from credential_inventory_organise_render import render

    result = organise.plan(store.load(), view.stored_secret_names(), with_dependents=not args.no_dependents)
    if args.apply_drafts:
        result["written"] = organise.apply_drafts(result)
        result["applied"] = True
    if args.json:
        emit_json(result)
        return 0
    print(render(result))
    if args.apply_drafts:
        written = result["written"]
        print(f"\nWrote {len(written['credentials'])} draft record(s) and {len(written['accounts'])} account(s), all unconfirmed. "
              "Confirm each with: aidevops secret record NAME --provider P --account REF")
    return 0


def cmd_verify_targets(args: argparse.Namespace) -> int:
    """Recorded credentials for a provider (or the given names, aliases resolved)."""
    data = store.load()
    credentials = data["credentials"]
    wanted = [names.alias_owner(data, name) or name for name in args.names] or sorted(credentials)
    targets = [name for name in wanted if (credentials.get(name) or {}).get("provider") == args.provider]
    for name in sorted(set(wanted) - set(targets)) if args.names else []:
        print(f"ERROR: {name} is not recorded for {args.provider}; record it first with: "
              f"aidevops secret record {name} --provider {args.provider} --account REF", file=sys.stderr)
    if args.names and len(targets) != len(wanted):
        return EXIT_INVALID
    print("\n".join(dict.fromkeys(targets)))
    return 0 if targets else 1


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
    injection = sub.add_parser("injection-map", help="alias/default name pairs used at injection")
    injection.add_argument("names", nargs="*")
    injection.set_defaults(func=cmd_injection_map)
    resolve_name = sub.add_parser("resolve-name", help="source credential for an alias or default variable")
    resolve_name.add_argument("name")
    resolve_name.set_defaults(func=cmd_resolve_name)
    dependents = sub.add_parser("dependents", help="find what uses a credential before rename/rotation")
    dependents.add_argument("name")
    dependents.add_argument("--json", action="store_true")
    dependents.set_defaults(func=cmd_dependents)
    add_drift_parsers(sub)


def add_drift_parsers(sub: argparse._SubParsersAction) -> None:
    drift = sub.add_parser("drift", help="offline expiry/overlap/ownership/freshness report")
    drift.add_argument("--json", action="store_true")
    drift.set_defaults(func=cmd_drift)
    owner = sub.add_parser("owner", help="which account and credentials hold a zone or resource")
    owner.add_argument("resource")
    owner.add_argument("--json", action="store_true")
    owner.set_defaults(func=cmd_owner)
    organise = sub.add_parser("organise", aliases=["organize"], help="plan-first cleanup of undescribed or duplicate credentials")
    organise.add_argument("--json", action="store_true")
    organise.add_argument("--apply-drafts", action="store_true", help="write unconfirmed draft records only")
    organise.add_argument("--no-dependents", action="store_true", help="skip the local dependents scan")
    organise.set_defaults(func=cmd_organise)
    targets = sub.add_parser("verify-targets", help="recorded credentials to verify for a provider")
    targets.add_argument("provider", choices=["cloudflare"])
    targets.add_argument("names", nargs="*")
    targets.set_defaults(func=cmd_verify_targets)


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
