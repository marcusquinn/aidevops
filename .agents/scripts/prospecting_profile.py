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


def _validated_pages(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
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
    return validated


def _collect_evidence(pages: list[dict[str, Any]]) -> dict[str, list[dict[str, str]]]:
    result: dict[str, list[dict[str, str]]] = {key: [] for key in ("facts", "limitations", "competitors", "communities", "language")}
    for page in pages:
        for sentence in _sentences(page["text"]):
            lowered = sentence.lower()
            if any(marker in lowered for marker in LIMITATION_MARKERS):
                result["limitations"].append(_evidence(page, sentence, "explicit limitation"))
            elif any(marker in lowered for marker in ("helps", "automate", "manage", "track", "for teams", "built for")):
                result["facts"].append(_evidence(page, sentence, "product capability or buyer language"))
            if any(marker in lowered for marker in ("alternative", "compare", "instead of", "versus", " vs. ")):
                result["competitors"].append(_evidence(page, sentence, "alternative or comparison language"))
            if any(marker in lowered for marker in COMMUNITY_MARKERS):
                result["communities"].append({**_evidence(page, sentence, "community hypothesis", "candidate"), "activation": "requires_relevant_thread_evidence"})
            if any(marker in lowered for marker in ("problem", "challenge", "pain", "struggle", "need to")):
                result["language"].append(_evidence(page, sentence, "buyer-language candidate"))
    return result


def _query_families(evidence: dict[str, list[dict[str, str]]]) -> list[dict[str, Any]]:
    candidates = [{"query": item["quote"].rstrip(".!?"), "stage": "problem", "status": "inferred", "evidence": [item]} for item in _unique(evidence["language"] + evidence["facts"])[:8]]
    candidates += [{"query": item["quote"].rstrip(".!?"), "stage": "comparison", "status": "observed", "evidence": [item]} for item in _unique(evidence["competitors"])[:5]]
    result = []
    seen: set[str] = set()
    for item in candidates:
        if item["query"] not in seen:
            seen.add(item["query"])
            result.append(item)
    return result


def generate_profile(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Generate source-grounded facts and explicitly marked hypotheses."""
    validated = _validated_pages(snapshot)

    product_name = snapshot.get("product_name")
    if not isinstance(product_name, str) or not product_name.strip():
        product_name = next((page.get("title") for page in validated if isinstance(page.get("title"), str) and page["title"].strip()), "Unknown product")
    evidence = _collect_evidence(validated)
    return {
        "schema": "aidevops.prospecting-profile/v1",
        "product": {"name": product_name, "status": "observed" if snapshot.get("product_name") else "inferred"},
        "profile": {
            "facts": _unique(evidence["facts"]), "explicit_limitations": _unique(evidence["limitations"]),
            "unsupported_negative_facts": [], "competitor_candidates": _unique(evidence["competitors"]),
        },
        "discovery_plan": {
            "query_families": _query_families(evidence), "community_candidates": _unique(evidence["communities"]),
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
