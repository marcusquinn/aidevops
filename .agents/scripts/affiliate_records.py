#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Closed record vocabularies and evidence-backed affiliate field validation."""

from __future__ import annotations

import re
from urllib.parse import urlsplit

from affiliate_storage import AffiliateError, date, integer, public_url

STATES = {"discovered", "preparation-ready", "awaiting-human", "submitted",
          "pending-review", "approved", "rejected", "closed"}
PURPOSES = {"home", "product", "pricing", "store", "bundle", "bot"}
OPAQUE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{2,95}$")


def enum_list(values, choices, *, nonempty: bool = False) -> None:
    if not isinstance(values, list):
        raise AffiliateError("invalid enumerated fields")
    if nonempty and not values:
        raise AffiliateError("missing enumerated fields")
    if any(value not in choices for value in values):
        raise AffiliateError("unsupported enumerated field")


def programme_fields(record: dict) -> None:
    for field in ("merchant", "network"):
        if not isinstance(record[field], str) or not OPAQUE.fullmatch(record[field]):
            raise AffiliateError("programme requires stable merchant/network identities")
    public_url(record["signup_url"])
    if "dashboard_url" in record:
        public_url(record["dashboard_url"])
    if record["later_stages"] not in {"unknown", "observed"}:
        raise AffiliateError("later programme stages must retain uncertainty")
    enum_list(record["requirements"], {"country", "business-identity", "tax-residency",
              "audience-evidence", "promotional-properties", "email-verification",
              "captcha", "agreement", "payout-handoff", "unknown"}, nonempty=True)


def account_fields(record: dict) -> None:
    if "deadline_at" in record:
        date(record["deadline_at"])
    expected = {"submitted": "submission-receipt", "pending-review": "review-notice",
                "approved": "approval-notice", "rejected": "rejection-notice", "closed": "closure-notice"}
    if record["state"] not in STATES or record["confirmation"] not in {"none", *expected.values()}:
        raise AffiliateError("invalid account observation")
    if record["state"] in expected and record["confirmation"] != expected[record["state"]]:
        raise AffiliateError("account state requires explicit confirmation evidence")


def link_evidence(record: dict) -> None:
    status = record.get("http_status")
    if status in {403, 405, 429} and record["link_state"] not in {"unknown", "observed"}:
        raise AffiliateError("access-limited links remain unverified")
    matched = all((status is not None, 200 <= (status or 0) < 300,
                   record.get("landing") == "matched", record.get("tracking") == "preserved"))
    if record["link_state"] == "verified" and not matched:
        raise AffiliateError("verification requires matched landing and intact tracking")
    degraded = record.get("landing") in {"wrong-product", "closed"} or record.get("tracking") == "lost"
    if record["link_state"] == "degraded" and not degraded:
        raise AffiliateError("degradation requires destination evidence")


def link_fields(record: dict) -> None:
    public_url(record["url"])
    if record["purpose"] not in PURPOSES or record["link_state"] not in {"observed", "verified", "degraded", "unknown"}:
        raise AffiliateError("invalid link observation")
    status = record.get("http_status")
    if status is not None and (not integer(status) or not 100 <= status <= 599):
        raise AffiliateError("invalid HTTP observation")
    if record.get("landing") not in {None, "matched", "wrong-product", "closed", "unknown"}:
        raise AffiliateError("invalid landing observation")
    if record.get("tracking") not in {None, "preserved", "lost", "unknown"}:
        raise AffiliateError("invalid tracking observation")
    enum_list(record.get("restrictions", ["unknown"]), {"unknown", "disclosure-required",
              "no-paid-search", "no-email", "no-social", "no-coupon", "approved-properties-only"})
    link_evidence(record)


def profile_fields(record: dict) -> None:
    if not re.fullmatch(r"protected:[A-Za-z0-9_-]{3,96}", str(record["profile_ref"])):
        raise AffiliateError("profile must reference separately protected material")
    if not isinstance(record["country"], str) or not re.fullmatch(r"[A-Z]{2}|unknown", record["country"]):
        raise AffiliateError("country must be evidenced, never inferred")
    if not isinstance(record["approved"], bool):
        raise AffiliateError("profile approval must be explicit")


def authorization_fields(record: dict) -> None:
    public_url(record["destination"])
    if urlsplit(record["destination"]).query:
        raise AffiliateError("signup destination must not contain query parameters")
    date(record["expires_at"])
    if record["action"] != "submit":
        raise AffiliateError("authorization must bind submission")
    for field in ("agreement_sha256", "profile_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", record[field]):
            raise AffiliateError("authorization must bind agreement and profile version")


def checkpoint_fields(record: dict) -> None:
    if record["outcome"] not in {"awaiting-reconciliation", "confirmed-submitted", "confirmed-not-submitted"}:
        raise AffiliateError("invalid reconciliation outcome")
    if not re.fullmatch(r"[0-9a-f]{64}", record["idempotency_id"]):
        raise AffiliateError("invalid idempotency identity")


def validate_fields(record: dict) -> None:
    {"programme": programme_fields, "account": account_fields, "link": link_fields,
     "profile": profile_fields, "authorization": authorization_fields,
     "checkpoint": checkpoint_fields}[record["kind"]](record)
    for field in ("profile_id", "authorization_id"):
        if field in record and not OPAQUE.fullmatch(str(record[field])):
            raise AffiliateError("invalid reference")
    if "data_scope" in record:
        enum_list(record["data_scope"], {"identity-reference", "country",
                  "promotional-properties", "audience-evidence"}, nonempty=True)
