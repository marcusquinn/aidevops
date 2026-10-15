#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline drift report (GH#34722); ownership lookup is credential_inventory_owner.

Works only from the registry and its cached verifications: no network, no
secret values. Findings are facts about recorded or cached data; anything
not in the cache is reported as unknown rather than guessed.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from itertools import combinations
from typing import Any

EXPIRY_WARN_DAYS = 30
STALE_DAYS = 30
VERIFIABLE_PROVIDERS = {"cloudflare"}
CONVENTIONAL_PROVIDERS = {"cloudflare", "github", "hetzner", "vercel", "openai", "anthropic"}


def _parse_day(value: Any) -> date | None:
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _parse_time(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def zones_of(record: dict[str, Any]) -> tuple[set[str], str]:
    """Observed zones when verified, else recorded reach; plus the source label."""
    cache = record.get("verification")
    if cache and cache.get("zones") is not None:
        return {zone["name"] for zone in cache["zones"]}, "observed"
    return set((record.get("reach") or {}).get("zones") or []) - {"all"}, "recorded"


def expiry_findings(name: str, record: dict[str, Any], today: date) -> list[dict]:
    """Missing, never, or soon expiry (recorded value or verified token expiry)."""
    recorded = record.get("expires_at")
    observed = ((record.get("verification") or {}).get("token") or {}).get("expires_on")
    verified = bool(record.get("verification"))
    days = [day for day in (_parse_day(recorded), _parse_day(observed)) if day]
    if days:
        soonest = min(days)
        if soonest <= today + timedelta(days=EXPIRY_WARN_DAYS):
            state = "expired" if soonest < today else "expiring-soon"
            return [{"check": state, "credential": name, "detail": soonest.isoformat()}]
        return []
    if recorded == "never" or verified:
        return [{"check": "never-expires", "credential": name, "detail": "no expiry recorded or reported by provider"}]
    return [{"check": "expiry-unknown", "credential": name, "detail": "record --expires YYYY-MM-DD or never"}]


def overlap_findings(credentials: dict[str, dict]) -> list[dict]:
    """Same-provider tokens with identical or overlapping zone reach."""
    findings = []
    for (left, lrec), (right, rrec) in combinations(sorted(credentials.items()), 2):
        if lrec.get("provider") != rrec.get("provider"):
            continue
        (lzones, lsrc), (rzones, rsrc) = zones_of(lrec), zones_of(rrec)
        shared = lzones & rzones
        if not shared:
            continue
        check = "identical-reach" if lzones == rzones else "overlapping-reach"
        findings.append({"check": check, "credential": left, "other": right,
                         "detail": ", ".join(sorted(shared)), "source": f"{lsrc}/{rsrc}"})
    return findings


def zone_account_findings(credentials: dict[str, dict]) -> list[dict]:
    """Zones seen under more than one account, and non-active (e.g. moved) zones."""
    accounts: dict[str, set[str]] = {}
    findings = []
    for name, record in sorted(credentials.items()):
        for zone in (record.get("verification") or {}).get("zones") or []:
            accounts.setdefault(zone["name"], set()).add(zone["account"])
            if zone.get("status") not in ("active", ""):
                findings.append({"check": "zone-not-active", "credential": name,
                                 "detail": f"{zone['name']} status {zone['status']}"})
    for zone, refs in sorted(accounts.items()):
        if len(refs) > 1:
            findings.append({"check": "zone-in-multiple-accounts", "detail": zone, "accounts": sorted(refs)})
    return findings


def account_findings(data: dict[str, Any], name: str, record: dict[str, Any]) -> list[dict]:
    """Recorded account name absent from the accounts the token actually sees."""
    cache = record.get("verification")
    account = (data.get("provider_accounts") or {}).get(record.get("account_ref") or "")
    if not cache or not account:
        return []
    seen = {str(item.get("name", "")).casefold() for item in cache.get("accounts") or []}
    if str(account.get("name", "")).casefold() in seen:
        return []
    names = ", ".join(sorted(item.get("name", "") for item in cache.get("accounts") or [])) or "none"
    return [{"check": "account-mismatch", "credential": name,
             "detail": f"recorded '{account.get('name')}', token sees: {names}"}]


def freshness_findings(name: str, record: dict[str, Any], now: datetime) -> list[dict]:
    """Verifiable credentials never verified, or verified too long ago."""
    if record.get("provider") not in VERIFIABLE_PROVIDERS:
        return []
    verified = _parse_time((record.get("verification") or {}).get("verified_at"))
    if verified is None:
        return [{"check": "unverified", "credential": name, "detail": f"aidevops secret verify {record['provider']} {name}"}]
    if now - verified > timedelta(days=STALE_DAYS):
        return [{"check": "stale-verification", "credential": name, "detail": verified.date().isoformat()}]
    return []


def drift(data: dict[str, Any], stored: list[str] | None, now: datetime | None = None) -> dict[str, Any]:
    """All findings; `stored` is the names-only stored listing (None = unavailable)."""
    now = now or datetime.now(timezone.utc)
    credentials = data.get("credentials") or {}
    findings: list[dict] = []
    for name, record in sorted(credentials.items()):
        findings += expiry_findings(name, record, now.date())
        findings += account_findings(data, name, record)
        findings += freshness_findings(name, record, now)
    findings += overlap_findings(credentials)
    findings += zone_account_findings(credentials)
    providers = {record.get("provider") for record in credentials.values()}
    findings += [{"check": "default-undeclared", "detail": provider}
                 for provider in sorted(providers & CONVENTIONAL_PROVIDERS) if provider not in (data.get("defaults") or {})]
    known = set(credentials) | {alias for record in credentials.values() for alias in record.get("aliases") or []}
    if stored is not None:
        findings += [{"check": "undescribed", "credential": name} for name in stored if name not in known]
    return {"findings": findings, "stored_listing": "ok" if stored is not None else "unavailable"}


def render_drift(report: dict[str, Any]) -> str:
    findings = report["findings"]
    if not findings:
        return "No drift findings."
    lines = [f"{len(findings)} finding(s):"]
    for item in findings:
        subject = item.get("credential") or ""
        other = f" ~ {item['other']}" if item.get("other") else ""
        detail = f"  -> {item['detail']}" if item.get("detail") else ""
        lines.append(f"  {item['check']:26} {subject}{other}{detail}")
    if report["stored_listing"] != "ok":
        lines.append("  (stored-secret listing unavailable; undescribed secrets not checked)")
    return "\n".join(lines)
