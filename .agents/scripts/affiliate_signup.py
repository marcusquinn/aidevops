#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline signup checkpoints. No browser, email, form submission or consent adapter."""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from affiliate_ledger import AffiliateError, canonical_json, catalog, date, latest


def identity(record: dict) -> tuple:
    return record["programme"], record["region"], record["stage"]


def referenced(events: list[dict], kind: str, identifier: str) -> dict:
    matches = [e["record"] for e in latest(events, kind) if e["record"]["id"] == identifier]
    if len(matches) != 1:
        raise AffiliateError("missing approved reference")
    return matches[0]


def authorization(events: list[dict], record: dict) -> dict:
    profile = referenced(events, "profile", record["profile_id"])
    if (identity(profile) != identity(record) or not profile["approved"]
            or profile["country"] == "unknown"
            or not set(record["data_scope"]) <= set(profile["data_scope"])
            or date(record["expires_at"]) <= datetime.now(timezone.utc)):
        raise AffiliateError("authorization profile, region, expiry or data scope conflicts")
    # Country eligibility is never inferred from region/language. Catalogue only
    # records public entrypoints; no provider has a verified automated adapter.
    return profile


def validate_transition(events: list[dict], record: dict) -> None:
    """Enforce immutable identities and checkpoint reconciliation even during import."""
    previous = [e["record"] for e in events
                if e["record"]["kind"] == record["kind"] and e["record"]["id"] == record["id"]]
    if any(identity(old) != identity(record) for old in previous):
        raise AffiliateError("entity identity cannot be rebound")
    if record["kind"] == "authorization":
        if previous:
            raise AffiliateError("authorization is immutable; issue a new scoped action")
        authorization(events, record)
    if record["kind"] != "checkpoint":
        return
    auth = referenced(events, "authorization", record["authorization_id"])
    if identity(auth) != identity(record):
        raise AffiliateError("checkpoint scope mismatch")
    expected = hashlib.sha256(canonical_json([identity(auth), auth["id"]]).encode()).hexdigest()
    if record["idempotency_id"] != expected or record["id"] != "submit-" + expected[:32]:
        raise AffiliateError("checkpoint identity mismatch")
    if record["source_url"] != auth["destination"]:
        raise AffiliateError("checkpoint confirmation destination mismatch")
    scoped = [e["record"] for e in latest(events, "checkpoint") if identity(e["record"]) == identity(record)]
    if record["outcome"] == "awaiting-reconciliation":
        authorization(events, auth)
        if any(e["outcome"] != "confirmed-not-submitted" for e in scoped):
            raise AffiliateError("reconcile existing submission before another attempt")
        if previous:
            raise AffiliateError("submission authorization has already been consumed")
    elif not previous or previous[-1]["outcome"] != "awaiting-reconciliation":
        raise AffiliateError("confirmation requires an uncertain pre-submit checkpoint")


def prepare(programme: str | None, *, live: bool = False) -> dict:
    """Truthful provider-specific requirements without needing credentials or a corpus."""
    matches = [p for p in catalog() if p["id"] == programme]
    if len(matches) != 1:
        raise AffiliateError("select a known programme")
    if live:
        raise AffiliateError("live adapters are disabled; separately authorized browser handoff required")
    return {"mode": "dry-run", "state": "awaiting-human", "programme": matches[0],
            "missing": ["approved protected profile", "evidenced country eligibility",
                        "current agreement", "separate per-programme submission authorization"],
            "submitted": False}


def checkpoint(ledger, identifier: str | None) -> dict:
    """Record intent BEFORE a separately authorized browser handoff, never execute it."""
    auth = referenced(ledger.replay(), "authorization", identifier)
    digest = hashlib.sha256(canonical_json([identity(auth), auth["id"]]).encode()).hexdigest()
    record = {"version": 1, "kind": "checkpoint", "id": "submit-" + digest[:32],
              "programme": auth["programme"], "region": auth["region"], "stage": auth["stage"],
              "observed_at": datetime.now(timezone.utc).isoformat(), "source_url": auth["destination"],
              "authorization_id": auth["id"], "idempotency_id": digest,
              "outcome": "awaiting-reconciliation"}
    event = ledger.append(record)
    return {"checkpoint": event["evidence_id"], "state": "awaiting-reconciliation",
            "submitted": False, "handoff": "live adapter disabled; inspect scoped confirmation before any retry"}
