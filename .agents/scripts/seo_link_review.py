#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Produce bounded, non-mutating internal-link and overlap review evidence."""

from __future__ import annotations

import hashlib
import json
import re
from collections import defaultdict
from typing import Any

TOKEN_RE = re.compile(r"[a-z0-9]+")
SCHEMA = "aidevops.seo-link-review/v1"
REPORT_SCHEMA = "aidevops.seo-link-review-report/v1"


class ReviewError(ValueError):
    """Raised when supplied offline review evidence is unsafe."""


def _require(value: bool, message: str) -> None:
    if not value:
        raise ReviewError(message)


def _text(value: Any, field: str) -> str:
    _require(isinstance(value, str) and value.strip(), f"{field} must be non-empty text")
    return value.strip()


def _tokens(value: str) -> set[str]:
    return set(TOKEN_RE.findall(value.lower()))


def _digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _source(value: Any, field: str) -> dict[str, str]:
    _require(isinstance(value, dict) and set(value) == {"source_id", "span"}, f"{field} must preserve source")
    return {key: _text(value[key], f"{field}.{key}") for key in value}


def validate(data: Any) -> dict[str, Any]:
    _require(isinstance(data, dict) and data.get("schema") == SCHEMA, "unknown link review schema")
    _require(set(data) == {"schema", "pages", "query_pairs", "max_candidates_per_page"}, "unsupported link review fields")
    limit = data["max_candidates_per_page"]
    _require(isinstance(limit, int) and 1 <= limit <= 100, "candidate limit is outside bounds")
    pages, seen = [], set()
    for index, raw in enumerate(data["pages"]):
        _require(isinstance(raw, dict), "page must be an object")
        allowed = {"page_id", "url", "title", "body", "status", "canonical", "links", "source"}
        _require(set(raw) == allowed, "page fields are unsupported")
        page_id = _text(raw["page_id"], "page_id")
        url = _text(raw["url"], "url")
        _require(page_id not in seen and url.startswith("/"), "page identity is invalid")
        seen.add(page_id)
        _require(raw["status"] == 200 and raw["canonical"] == url, "page destination evidence is invalid")
        links = raw["links"]
        _require(isinstance(links, list) and all(isinstance(item, str) and item.startswith("/") for item in links), "page links are invalid")
        pages.append({"page_id": page_id, "url": url, "title": _text(raw["title"], "title"), "body": _text(raw["body"], "body"), "status": 200, "canonical": url, "links": sorted(set(links)), "source": _source(raw["source"], "page.source")})
    _require(pages, "pages cannot be empty")
    pairs = []
    for raw in data["query_pairs"]:
        _require(isinstance(raw, dict) and set(raw) == {"query", "urls", "source", "metrics"}, "query pair fields are unsupported")
        urls = raw["urls"]
        _require(isinstance(urls, list) and len(set(urls)) > 1 and all(isinstance(url, str) and url.startswith("/") for url in urls), "query pair URLs are invalid")
        metrics = raw["metrics"]
        _require(isinstance(metrics, dict) and set(metrics) <= {"traffic", "conversions", "links"} and all(isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 for v in metrics.values()), "query metrics are invalid")
        pairs.append({"query": _text(raw["query"], "query"), "urls": sorted(set(urls)), "source": _source(raw["source"], "query.source"), "metrics": metrics})
    return {"schema": SCHEMA, "pages": pages, "query_pairs": pairs, "max_candidates_per_page": limit}


def _anchor(source: dict[str, Any], destination: dict[str, Any]) -> str | None:
    candidates = sorted(_tokens(destination["title"]), key=lambda term: (-len(term), term))
    body_lower = source["body"].lower()
    for term in candidates:
        match = re.search(rf"\b{re.escape(term)}\b", body_lower)
        if match:
            return source["body"][match.start():match.end()]
    return None


def _link_proposals(pages: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    proposals = []
    for source in pages:
        scored = []
        for destination in pages:
            if source["page_id"] == destination["page_id"] or destination["url"] in source["links"]:
                continue
            overlap = len(_tokens(source["body"]) & _tokens(destination["title"]))
            anchor = _anchor(source, destination)
            if overlap and anchor:
                scored.append((overlap, destination, anchor))
        for _, destination, anchor in sorted(scored, key=lambda item: (-item[0], item[1]["page_id"]))[:limit]:
            evidence = {"source": source["source"], "destination": destination["source"], "anchor": anchor, "source_hash": _digest(source["body"]), "destination_hash": _digest({"url": destination["url"], "canonical": destination["canonical"], "status": destination["status"]})}
            proposals.append({"evidence_id": _digest(evidence), "source_url": source["url"], "destination_url": destination["url"], "anchor": anchor, "source_location": source["source"], "reason": "observed_anchor_and_topical_overlap", "evidence": evidence, "non_mutating": True})
    return proposals


def _cannibalization(pages: list[dict[str, Any]], pairs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    page_by_url = {page["url"]: page for page in pages}
    cannibalization = []
    for pair in pairs:
        known = [page_by_url[url] for url in pair["urls"] if url in page_by_url]
        if len(known) != len(pair["urls"]):
            outcome, action = "unknown", "review"
        else:
            intents = {frozenset(_tokens(page["title"])) for page in known}
            outcome, action = ("duplication", "differentiate_or_merge_review") if len(intents) == 1 else ("complementary", "differentiate")
        evidence = {"query": pair["query"], "source": pair["source"], "urls": pair["urls"], "metrics": pair["metrics"]}
        cannibalization.append({"evidence_id": _digest(evidence), "query": pair["query"], "urls": pair["urls"], "classification": outcome, "proposal": action, "metrics": pair["metrics"], "evidence": evidence, "non_mutating": True})
    return cannibalization


def analyze(data: Any) -> dict[str, Any]:
    request = validate(data)
    pages = request["pages"]
    return {"schema": REPORT_SCHEMA, "authority": "non_mutating_recommendations_only", "candidate_recall": {"max_candidates_per_page": request["max_candidates_per_page"], "method": "deterministic_observed_anchor"}, "link_proposals": _link_proposals(pages, request["max_candidates_per_page"]), "cannibalization": _cannibalization(pages, request["query_pairs"])}
