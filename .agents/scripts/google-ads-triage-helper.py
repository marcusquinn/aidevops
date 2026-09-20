#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, non-mutating Google Ads search-term triage rules."""

from __future__ import annotations

import hashlib
import json
from typing import Any


JOBS = (
    "search_intent", "negative_conflict", "keyword_ad_group_fit", "rsa_relevance",
    "landing_match", "recommendation_routing", "term_classification", "policy_routing",
)


def stable_id(prefix: str, value: Any) -> str:
    """Return a deterministic evidence identifier without exposing account data."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return f"{prefix}-{hashlib.sha256(encoded).hexdigest()[:16]}"


def normalize_term(value: Any) -> str:
    """Normalize only spacing and case; semantic similarity is not a match rule."""
    return " ".join(str(value or "").casefold().split())


def negative_blocks(term: str, negative: dict[str, Any]) -> bool:
    """Apply conservative documented negative keyword matching semantics.

    Exact negatives block only the identical normalized term; phrase negatives block
    a contiguous term phrase; broad negatives require all negative words.  Close
    variants and semantic similarity intentionally do not block a query.
    """
    query_words = normalize_term(term).split()
    negative_words = normalize_term(negative.get("term")).split()
    if not query_words or not negative_words:
        return False
    match_type = str(negative.get("match_type", "")).casefold()
    if match_type == "exact":
        return query_words == negative_words
    if match_type == "phrase":
        size = len(negative_words)
        return any(query_words[index:index + size] == negative_words for index in range(len(query_words) - size + 1))
    if match_type == "broad":
        return set(negative_words) <= set(query_words)
    return False


def _outcome(kind: str, evidence: dict[str, Any], *, action: str = "review", reason: str | None = None) -> dict[str, Any]:
    return {
        "job": kind,
        "outcome": action,
        "reason": reason,
        "evidence_id": stable_id("evidence", {"job": kind, **evidence}),
        "evidence": evidence,
        "non_mutating": True,
    }


def _term_context(term: dict[str, Any], definitions: dict[str, Any]) -> tuple[dict[str, Any], bool, bool, str, dict[str, Any] | None]:
    """Collect observed state once for each of the independent triage rubrics."""
    query = normalize_term(term.get("query"))
    metrics = term.get("metrics") if isinstance(term.get("metrics"), dict) else {}
    protected = metrics.get("conversions") not in (None, 0) or metrics.get("profitable") is True
    missing = metrics.get("conversions") is None or metrics.get("spend") is None
    aliases = {normalize_term(item) for item in definitions.get("brand_aliases", [])}
    classification = "brand" if query in aliases else ("ambiguous" if not query else "non_brand")
    negatives = term.get("negative_keywords") if isinstance(term.get("negative_keywords"), list) else []
    negative = next((item for item in negatives if isinstance(item, dict) and negative_blocks(query, item)), None)
    return {"query": query, "term_id": term.get("id"), "scope": term.get("scope"), "metrics": metrics}, protected, missing, classification, negative


def _content_outcomes(term: dict[str, Any], context: dict[str, Any]) -> list[dict[str, Any]]:
    """Return independent search, ad, and landing-page review outcomes."""
    query = context["query"]
    return [
        _outcome("search_intent", context, action="review" if not query else "proposal", reason="missing_query" if not query else None),
        _outcome("keyword_ad_group_fit", context, action="review" if not term.get("ad_group") else "proposal"),
        _outcome("rsa_relevance", context, action="review" if not term.get("rsa") else "proposal"),
        _outcome("landing_match", context, action="review" if not term.get("landing_page") else "proposal"),
    ]


def _safety_outcomes(term: dict[str, Any], context: dict[str, Any], protected: bool, missing: bool, classification: str, negative: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Keep actions requiring outcome evidence or human review non-mutating."""
    review_reason = "protected_or_missing_outcomes" if protected or missing else None
    negative_action = "review" if review_reason else ("proposal" if negative else "no_action")
    return [
        _outcome("negative_conflict", {**context, "negative": negative}, action=negative_action, reason=review_reason),
        _outcome("recommendation_routing", context, action="review" if missing else "proposal"),
        _outcome("term_classification", {**context, "classification": classification}, action="review" if classification == "ambiguous" else "proposal"),
        _outcome("policy_routing", {**context, "disapproval": term.get("disapproval")}, action="proposal" if term.get("disapproval") else "no_action"),
    ]


def triage_term(term: dict[str, Any], definitions: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Produce all eight explicit, evidence-backed outcomes for one observed term."""
    definitions = definitions or {}
    context, protected, missing, classification, negative = _term_context(term, definitions)
    return _content_outcomes(term, context) + _safety_outcomes(term, context, protected, missing, classification, negative)


def analyze(snapshot: dict[str, Any], decisions: dict[str, Any]) -> dict[str, Any]:
    """Analyze a supplied offline snapshot; never calls provider APIs or mutates accounts."""
    terms = snapshot.get("search_terms")
    if not isinstance(terms, list):
        raise ValueError("search_terms must be an array")
    definitions = snapshot.get("definitions") if isinstance(snapshot.get("definitions"), dict) else {}
    results = [outcome for term in terms if isinstance(term, dict) for outcome in triage_term(term, definitions)]
    return {
        "schema": "aidevops.google-ads-triage-report/v1",
        "request_id": decisions.get("request_id"),
        "authority": "non_mutating_recommendations_only",
        "coverage": {job: sum(item["job"] == job for item in results) for job in JOBS},
        "results": results,
    }
