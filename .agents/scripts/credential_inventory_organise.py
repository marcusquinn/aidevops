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

import re
from typing import Any

import credential_inventory_drift as drift
import credential_inventory_store as store
from credential_inventory_fields import DEFAULT_ENV, InventoryError, now_iso

# Known name prefixes; first match wins, so longer prefixes come first.
PROVIDER_PREFIXES = (
    ("CLOUDFLARE_", "cloudflare"), ("CF_", "cloudflare"),
    ("GITHUB_", "github"), ("GH_", "github"),
    ("HCLOUD_", "hetzner"), ("HETZNER_", "hetzner"),
    ("OPENAI_", "openai"), ("ANTHROPIC_", "anthropic"), ("VERCEL_", "vercel"),
    ("GITLAB_", "gitlab"), ("AWS_", "aws"), ("DIGITALOCEAN_", "digitalocean"),
    ("STRIPE_", "stripe"), ("SENTRY_", "sentry"), ("POSTHOG_", "posthog"),
    ("COOLIFY_", "coolify"), ("HOSTINGER_", "hostinger"), ("BACKBLAZE_", "backblaze"),
)
KIND_SUFFIXES = (
    ("_API_TOKEN", "api_token"), ("_ACCESS_TOKEN", "access_token"), ("_API_KEY", "api_key"),
    ("_ACCOUNT_ID", "account_id"), ("_TOKEN_NAME", "token_name"), ("_TOKEN", "token"),
    ("_SECRET", "secret"), ("_PASSWORD", "password"), ("_KEY", "key"),
)


def infer(name: str) -> dict[str, Any] | None:
    """Provider, kind and account tag implied by a name; None if unrecognised."""
    for prefix, provider in PROVIDER_PREFIXES:
        if name.startswith(prefix):
            break
    else:
        return None
    rest = name[len(prefix):]
    kind = next((kind for suffix, kind in KIND_SUFFIXES if ("_" + rest).endswith(suffix)), None)
    suffix = next((suffix for suffix, k in KIND_SUFFIXES if k == kind), "")
    middle = ("_" + rest)[: -len(suffix)].strip("_") if suffix else ""
    tag = middle.split("_")[0].lower() if middle else None
    return {"provider": provider, "kind": kind, "tag": tag, "evidence": f"name prefix {prefix}"}


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "account"


def draft_for(data: dict[str, Any], name: str) -> dict[str, Any] | None:
    """A draft record for an undescribed stored secret."""
    guess = infer(name)
    if guess is None:
        return None
    draft = {"name": name, "provider": guess["provider"], "kind": guess["kind"], "confirmed": False,
             "evidence": guess["evidence"]}
    if name == DEFAULT_ENV.get(guess["provider"]):
        draft["note"] = "bare conventional variable stored directly; it is used as-is; record its account"
        return draft
    ref = f"{guess['provider']}-{guess['tag']}" if guess["tag"] else None
    account = (data.get("provider_accounts") or {}).get(ref or "")
    if account and account.get("provider") == guess["provider"]:
        draft["account_ref"] = ref
        draft["evidence"] += f"; account tag {guess['tag'].upper()} matches account {ref}"
    elif guess["tag"]:
        draft["account_hint"] = guess["tag"].upper()
    return draft


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


def _used(counts: dict[str, dict] | None, name: str) -> str:
    if counts is None:
        return ""
    item = counts.get(name) or {}
    dynamic = f", {item['possible_dynamic']} possible-dynamic" if item.get("possible_dynamic") else ""
    return f"  [{item.get('literal', 0)} reference(s){dynamic}]"


def _render_drafts(result: dict[str, Any], counts: dict | None) -> list[str]:
    if not result["drafts"]:
        return []
    lines = [f"\nDraft records ({len(result['drafts'])}, unconfirmed; write with --apply-drafts):"]
    for draft in result["drafts"]:
        account = draft.get("account_ref") or (f"tag {draft['account_hint']}?" if draft.get("account_hint") else "unknown")
        lines.append(f"  {draft['name']}  -> {draft['provider']}, kind {draft['kind'] or '?'}, account {account}{_used(counts, draft['name'])}")
        if draft.get("note"):
            lines.append(f"      note {draft['note']}")
    return lines


def _render_aliases(result: dict[str, Any], counts: dict | None) -> list[str]:
    if not result["aliases"]:
        return []
    lines = ["\nDuplicate or overlapping tokens (aliases, never renames):"]
    for item in result["aliases"]:
        if item["action"] != "alias":
            lines.append(f"  review {' / '.join(item['credentials'])}  -> overlapping reach {item['shared']}")
            continue
        lines.append(f"  keep {item['keep']}{_used(counts, item['keep'])}, retire {item['retire']}"
                     f"{_used(counts, item['retire'])}; identical reach {item['shared']}")
        lines += [f"      {number}. {step}" for number, step in enumerate(item["steps"], 1)]
    return lines


def _render_defaults(result: dict[str, Any]) -> list[str]:
    if not result["defaults"]:
        return []
    lines = ["\nDefault decisions needed:"]
    for item in result["defaults"]:
        bare = " (bare variable stored directly)" if item["stored_bare_variable"] else ""
        lines.append(f"  {item['provider']} ({item['variable']}){bare}, choose one:")
        lines += [f"      {command}" for command in item["commands"]]
    return lines


def _render_recorded(result: dict[str, Any], counts: dict | None) -> list[str]:
    if counts is None:
        return []
    drafted = {draft["name"] for draft in result["drafts"]}
    lines = ["\nRecorded credentials:"] + [f"  {name}{_used(counts, name)}" for name in sorted(counts) if name not in drafted]
    if not result["dependents_complete"]:
        lines.append("  (some sources were skipped; run `aidevops secret dependents NAME` before changing any name)")
    return lines


def render(result: dict[str, Any]) -> str:
    counts = result["dependents"]
    lines = ["Credential organisation plan (nothing is renamed, deleted or re-pointed)"]
    lines += _render_drafts(result, counts)
    if result["unrecognised"]:
        lines.append("\nUnrecognised (record manually): " + ", ".join(result["unrecognised"]))
    if result["accounts"]:
        lines.append("\nAccount refs from verified account names:")
        lines += [f"  {item['credential']}  -> {item['account_ref']} ({item['account_name']}{', exists' if item['exists'] else ', new'})"
                  for item in result["accounts"]]
    lines += _render_aliases(result, counts) + _render_defaults(result) + _render_recorded(result, counts)
    if result["stored_listing"] != "ok":
        lines.append("\nStored-secret listing unavailable; undescribed secrets were not checked.")
    return "\n".join(lines)
