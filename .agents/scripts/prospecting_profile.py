#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Produce a reviewable prospecting profile from supplied site snapshots only."""

from __future__ import annotations

import re
from typing import Any

INSTRUCTION_MARKERS = ("ignore previous", "system message", "assistant:", "developer message")
LIMITATION_MARKERS = ("not for", "does not", "don't support", "do not support", "without")
COMMUNITY_MARKERS = ("community", "forum", "reddit", "slack", "discord")


class ProfileError(ValueError):
    """Raised when a supplied snapshot cannot be safely interpreted."""


def _text(page: dict[str, Any]) -> str:
    value = page.get("text", "")
    if not isinstance(value, str):
        raise ProfileError("each page text must be a string")
    return " ".join(value.split())


def _evidence(page: dict[str, Any], quote: str, claim: str, state: str = "observed") -> dict[str, str]:
    return {"url": page["url"], "quote": quote, "claim": claim, "status": state}


def _sentences(text: str) -> list[str]:
    return [item.strip() for item in re.split(r"(?<=[.!?])\s+", text) if item.strip()]


def _unique(items: list[Any]) -> list[Any]:
    seen: set[str] = set()
    result = []
    for item in items:
        key = repr(item)
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def generate_profile(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Generate source-grounded facts and explicitly marked hypotheses.

    No network access occurs here: callers must supply authorized snapshots.
    """
    pages = snapshot.get("pages")
    if not isinstance(pages, list) or not pages:
        raise ProfileError("snapshot requires at least one page")
    validated = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("url"), str):
            raise ProfileError("each page requires a URL")
        text = _text(page)
        lowered = text.lower()
        markers = [lowered.index(marker) for marker in INSTRUCTION_MARKERS if marker in lowered]
        if markers:
            text = text[:min(markers)].rstrip()
        validated.append({**page, "text": text})

    product_name = snapshot.get("product_name")
    if not isinstance(product_name, str) or not product_name.strip():
        product_name = next((page.get("title") for page in validated if isinstance(page.get("title"), str) and page["title"].strip()), "Unknown product")
    facts: list[dict[str, str]] = []
    limitations: list[dict[str, str]] = []
    competitors: list[dict[str, str]] = []
    communities: list[dict[str, str]] = []
    language: list[dict[str, str]] = []
    for page in validated:
        for sentence in _sentences(page["text"]):
            lowered = sentence.lower()
            if any(marker in lowered for marker in LIMITATION_MARKERS):
                limitations.append(_evidence(page, sentence, "explicit limitation"))
            elif any(marker in lowered for marker in ("helps", "automate", "manage", "track", "for teams", "built for")):
                facts.append(_evidence(page, sentence, "product capability or buyer language"))
            if any(marker in lowered for marker in ("alternative", "compare", "instead of", "versus", " vs. ")):
                competitors.append(_evidence(page, sentence, "alternative or comparison language"))
            if any(marker in lowered for marker in COMMUNITY_MARKERS):
                communities.append({**_evidence(page, sentence, "community hypothesis", "candidate"), "activation": "requires_relevant_thread_evidence"})
            if any(marker in lowered for marker in ("problem", "challenge", "pain", "struggle", "need to")):
                language.append(_evidence(page, sentence, "buyer-language candidate"))

    query_families = []
    for evidence in _unique(language + facts)[:8]:
        phrase = evidence["quote"].rstrip(".!?")
        query_families.append({"query": phrase, "stage": "problem", "status": "inferred", "evidence": [evidence]})
    for evidence in _unique(competitors)[:5]:
        query_families.append({"query": evidence["quote"].rstrip(".!?"), "stage": "comparison", "status": "observed", "evidence": [evidence]})
    deduplicated_queries = []
    seen_queries: set[str] = set()
    for item in query_families:
        if item["query"] not in seen_queries:
            seen_queries.add(item["query"])
            deduplicated_queries.append(item)
    return {
        "schema": "aidevops.prospecting-profile/v1",
        "product": {"name": product_name, "status": "observed" if snapshot.get("product_name") else "inferred"},
        "profile": {
            "facts": _unique(facts), "explicit_limitations": _unique(limitations),
            "unsupported_negative_facts": [], "competitor_candidates": _unique(competitors),
        },
        "discovery_plan": {
            "query_families": deduplicated_queries, "community_candidates": _unique(communities),
            "active_communities": [], "exploration_allocation": {"max_fraction": 0.2, "status": "editable"},
            "controls": {"manual_edit": True, "import": True, "disable": True},
        },
        "warnings": ["No limitation is inferred from an absent page.", "Saving a profile does not start collection or scans."],
    }


def store_payload(result: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Convert review output to the foundation's separate versioned documents."""
    profile = result["profile"]
    discovery = result["discovery_plan"]
    return (
        {"facts": [item["quote"] for item in profile["facts"]], "claims": [item["quote"] for item in profile["explicit_limitations"]], "competitors": [item["quote"] for item in profile["competitor_candidates"]]},
        {"keywords": [item["query"] for item in discovery["query_families"]], "communities": [], "source_preferences": [], "budgets": {"exploration_fraction": discovery["exploration_allocation"]["max_fraction"]}},
    )
