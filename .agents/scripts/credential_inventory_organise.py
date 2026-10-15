#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan-first organisation of an inconsistent credential store (GH#34723).

Combines the names-only stored listing, the registry and the verification
cache into proposals. Nothing here reads secret values, renames, deletes,
declares aliases or sets defaults: those change what gets injected, so they
stay proposals. `apply_drafts` writes only unconfirmed draft metadata.
"""

from __future__ import annotations

from typing import Any

import credential_inventory_drift as drift
import credential_inventory_store as store
from credential_inventory_fields import DEFAULT_ENV, InventoryError, now_iso
from credential_inventory_organise_infer import draft_for, slug


def account_proposals(data: dict[str, Any]) -> list[dict[str, Any]]:
    """Account refs for recorded credentials from their verified account names."""
    accounts = data.get("provider_accounts") or {}
    proposals = []
    for name, record in sorted((data.get("credentials") or {}).items()):
        seen = (record.get("verification") or {}).get("accounts") or []
        if record.get("account_ref") or len(seen) != 1 or not seen[0].get("name"):
            continue
        provider, label = record["provider"], seen[0]["name"]
        existing = next((ref for ref, acc in sorted(accounts.items())
                         if acc.get("provider") == provider and str(acc.get("name", "")).casefold() == label.casefold()), None)
        proposals.append({"credential": name, "provider": provider, "account_ref": existing or f"{provider}-{slug(label)}",
                          "account_name": label, "exists": existing is not None, "confirmed": False,
                          "evidence": f"verified token sees exactly one account: {label}"})
    return proposals


def _keep_rank(name: str, provider: str, counts: dict[str, dict] | None) -> tuple:
    """Prefer an account-tagged name, then the more-referenced one, then alphabetical."""
    used = ((counts or {}).get(name) or {}).get("literal", 0)
    return (name == DEFAULT_ENV.get(provider), -used, name)


def alias_proposals(data: dict[str, Any], counts: dict[str, dict] | None) -> list[dict[str, Any]]:
    """Identical reach → keep one name and alias the other; overlap → review only."""
    proposals = []
    for finding in drift.overlap_findings(data.get("credentials") or {}):
        pair = [finding["credential"], finding["other"]]
        if finding["check"] != "identical-reach":
            proposals.append({"credentials": pair, "action": "review-scopes", "shared": finding["detail"],
                              "source": finding["source"]})
            continue
        provider = data["credentials"][pair[0]]["provider"]
        keep, retire = sorted(pair, key=lambda name, p=provider: _keep_rank(name, p, counts))
        proposals.append({
            "credentials": pair, "action": "alias", "keep": keep, "retire": retire, "shared": finding["detail"],
            "source": finding["source"],
            "steps": [f"aidevops secret dependents {retire}", f"move consumers from {retire} to {keep}",
                      f"delete the stored {retire}", f"aidevops secret alias {keep} {retire}"],
        })
    return proposals


def default_decisions(data: dict[str, Any], drafts: list[dict]) -> list[dict[str, Any]]:
    """Providers whose default is undeclared, with candidate credentials."""
    defaults = data.get("defaults") or {}
    candidates: dict[str, set[str]] = {}
    for name, record in (data.get("credentials") or {}).items():
        candidates.setdefault(record["provider"], set()).add(name)
    for draft in drafts:
        candidates.setdefault(draft["provider"], set()).add(draft["name"])
    decisions = []
    for provider, names in sorted(candidates.items()):
        if provider in defaults or provider not in DEFAULT_ENV:
            continue
        options = sorted(names - {DEFAULT_ENV[provider]})
        decisions.append({"provider": provider, "variable": DEFAULT_ENV[provider], "candidates": options,
                          "stored_bare_variable": DEFAULT_ENV[provider] in names,
                          "commands": [f"aidevops secret default {provider} {name}" for name in options]
                          + [f"aidevops secret default {provider} --none"]})
    return decisions


def dependent_counts(data: dict[str, Any], names: list[str]) -> tuple[dict[str, dict], bool]:
    """One local scan for every name; hits are attributed to the canonical name."""
    import credential_inventory_dependents as dependents

    owner = {name: name for name in names}
    for name in names:
        for alias in (data.get("credentials") or {}).get(name, {}).get("aliases") or []:
            owner[alias] = name
    if not owner:
        return {}, True
    result = dependents.find_dependents(sorted(owner))
    counts = {name: {"literal": 0, "possible_dynamic": 0} for name in names}
    for hit in result["literal"]:
        counts[owner[hit["matched"]]]["literal"] += 1
    for hit in result["possible_dynamic"]:
        prefix, _, tail = hit["matched"].partition("_*_")
        for name in names:
            if name.startswith(prefix + "_") and name.endswith("_" + tail):
                counts[name]["possible_dynamic"] += 1
    return counts, not result["skipped"]


def plan(data: dict[str, Any], stored: list[str] | None, with_dependents: bool = True) -> dict[str, Any]:
    credentials = data.get("credentials") or {}
    known = set(credentials) | {alias for record in credentials.values() for alias in record.get("aliases") or []}
    undescribed = [name for name in stored or [] if name not in known]
    drafts = [draft for draft in (draft_for(data, name) for name in undescribed) if draft]
    drafted = {draft["name"] for draft in drafts}
    counts, complete = dependent_counts(data, sorted(set(credentials) | drafted)) if with_dependents else (None, False)
    return {
        "stored_listing": "ok" if stored is not None else "unavailable",
        "drafts": drafts,
        "unrecognised": [name for name in undescribed if name not in drafted],
        "accounts": account_proposals(data),
        "aliases": alias_proposals(data, counts),
        "defaults": default_decisions(data, drafts),
        "dependents": counts,
        "dependents_complete": complete,
        "applied": False,
    }


def apply_drafts(result: dict[str, Any]) -> dict[str, list[str]]:
    """Write unconfirmed draft metadata only; never names, values, aliases or defaults."""
    written: dict[str, list[str]] = {"credentials": [], "accounts": []}
    with store.locked() as data:
        for proposal in result["accounts"]:
            record = data["credentials"].get(proposal["credential"])
            if record is None or record.get("account_ref"):
                continue
            if proposal["account_ref"] not in data["provider_accounts"]:
                store.add_account(data, proposal["account_ref"], proposal["provider"], proposal["account_name"],
                                  evidence=proposal["evidence"][:300], confirmed=False)
                written["accounts"].append(proposal["account_ref"])
            record["account_ref"] = proposal["account_ref"]
            record["draft"] = {"confirmed": False, "evidence": proposal["evidence"], "drafted_at": now_iso()}
            written["credentials"].append(proposal["credential"])
        for draft in result["drafts"]:
            if draft["name"] in data["credentials"]:
                continue
            try:
                record = store.record_credential(data, draft["name"], draft["provider"], kind=draft["kind"],
                                                 account_ref=draft.get("account_ref"))
            except InventoryError:
                continue
            record["draft"] = {"confirmed": False, "evidence": draft["evidence"], "drafted_at": now_iso()}
            written["credentials"].append(draft["name"])
    return written
