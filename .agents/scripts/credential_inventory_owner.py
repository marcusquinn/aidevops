#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline resource-ownership lookup (GH#34722).

Answers which account and credentials hold a zone or resource from cached
verifications, falling back to recorded reach only for unverified
credentials. Anything else is `unknown`; it never guesses.
"""

from __future__ import annotations

from typing import Any

from credential_inventory_drift import zones_of


def observed_hits(cache: dict[str, Any], resource: str) -> list[tuple[str, str, str]]:
    """(matched, account fingerprint, type) for cached zones and resources."""
    hits = [(zone["name"], zone["account"], "zone") for zone in cache.get("zones") or []
            if resource == zone["name"] or resource.endswith("." + zone["name"])]
    for item in cache.get("resources") or []:
        label = f"{item['type']}:{item['name']}"
        if resource in (item["name"].lower(), label.lower()):
            hits.append((label, item["account"], item["type"]))
    return hits


def _add_observed(matches: dict[tuple, dict], name: str, cache: dict[str, Any], resource: str) -> None:
    labels = {item["fingerprint"]: item.get("name") for item in cache.get("accounts") or []}
    for matched, account, kind in observed_hits(cache, resource):
        entry = matches.setdefault((matched, account), {
            "matched": matched, "type": kind, "account_fingerprint": account,
            "account_name": labels.get(account), "credentials": [], "source": "observed",
            "verified_at": cache.get("verified_at")})
        entry["credentials"].append(name)


def _add_recorded(matches: dict[tuple, dict], data: dict[str, Any], name: str, record: dict[str, Any], resource: str) -> None:
    ref = record.get("account_ref")
    account = (data.get("provider_accounts") or {}).get(ref or "") or {}
    entry = matches.setdefault((resource, ref), {
        "matched": resource, "type": "zone", "account_ref": ref, "account_name": account.get("name"),
        "credentials": [], "source": "recorded"})
    entry["credentials"].append(name)


def owner(data: dict[str, Any], resource: str) -> dict[str, Any]:
    """Which account/credentials hold a zone or resource, from cache/records only."""
    resource = resource.strip().lower().rstrip(".")
    matches: dict[tuple, dict] = {}
    for name, record in sorted((data.get("credentials") or {}).items()):
        cache = record.get("verification") or {}
        if cache:
            _add_observed(matches, name, cache, resource)
        elif resource in zones_of(record)[0]:
            _add_recorded(matches, data, name, record, resource)
    if not matches:
        return {"resource": resource, "status": "unknown"}
    found = list(matches.values())
    accounts = {entry.get("account_fingerprint") or entry.get("account_ref") for entry in found}
    return {"resource": resource, "status": "ambiguous" if len(accounts) > 1 else "found", "matches": found}


def render_owner(result: dict[str, Any]) -> str:
    if result["status"] == "unknown":
        return f"{result['resource']}: unknown (not in cached verifications or recorded reach)"
    lines = [f"{result['resource']}: {result['status']}"]
    for entry in result["matches"]:
        account = entry.get("account_name") or entry.get("account_fingerprint") or entry.get("account_ref")
        lines.append(f"  {entry['matched']}  account: {account}  credentials: {', '.join(entry['credentials'])}  [{entry['source']}]")
    return "\n".join(lines)
