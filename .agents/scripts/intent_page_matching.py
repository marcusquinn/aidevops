#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Deterministic, offline intent-to-page matching evidence."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

PAGES_SCHEMA = "aidevops.intent-pages/v1"
DECISIONS_SCHEMA = "aidevops.intent-decisions/v1"
REPORT_SCHEMA = "aidevops.intent-page-report/v1"
TOKEN_RE = re.compile(r"[a-z0-9]+")
MAX_CANDIDATES = 20


class MatchError(ValueError):
    """Raised when offline matching evidence is unsafe or incomplete."""


def _tokens(value: str) -> set[str]:
    return set(TOKEN_RE.findall(value.lower()))


def _require(value: bool, message: str) -> None:
    if not value:
        raise MatchError(message)


def _object(value: Any, field: str) -> dict[str, Any]:
    _require(isinstance(value, dict), f"{field} must be an object")
    return value


def _list(value: Any, field: str) -> list[Any]:
    _require(isinstance(value, list), f"{field} must be an array")
    return value


def _text(value: Any, field: str) -> str:
    _require(isinstance(value, str) and value.strip(), f"{field} must be a non-empty string")
    return value.strip()


def _versioned(value: Any, field: str) -> dict[str, str]:
    item = _object(value, field)
    _require(set(item) == {"id", "version"}, f"{field} requires known id and version")
    return {key: _text(item[key], f"{field}.{key}") for key in item}


def _source(value: Any, field: str) -> dict[str, str]:
    item = _object(value, field)
    _require(set(item) == {"source_id", "span"}, f"{field} must preserve source passage")
    return {key: _text(item[key], f"{field}.{key}") for key in item}


def validate_pages(value: Any) -> dict[str, Any]:
    data = _object(value, "pages")
    _require(data.get("schema") == PAGES_SCHEMA, "unknown pages schema")
    rubric = _versioned(data.get("rubric"), "pages.rubric")
    pages = []
    seen = set()
    for index, raw in enumerate(_list(data.get("pages"), "pages.pages")):
        page = _object(raw, f"pages.pages[{index}]")
        required = {"page_id", "url", "title", "h1", "body", "source"}
        _require(required <= set(page) <= required | {"offer", "cta", "page_hash"}, "page fields are unsupported")
        page_id = _text(page["page_id"], "page_id")
        _require(page_id not in seen, "page IDs must be unique")
        seen.add(page_id)
        normalized = {key: _text(page[key], f"page.{key}") for key in ("page_id", "url", "title", "h1", "body")}
        normalized["source"] = _source(page["source"], "page.source")
        normalized["offer"] = _text(page["offer"], "page.offer") if "offer" in page else ""
        normalized["cta"] = _text(page["cta"], "page.cta") if "cta" in page else ""
        expected_hash = hashlib.sha256(json.dumps(normalized, sort_keys=True).encode()).hexdigest()
        supplied_hash = page.get("page_hash")
        _require(supplied_hash in (None, expected_hash), "page_hash does not match page evidence")
        normalized["page_hash"] = expected_hash
        pages.append(normalized)
    _require(bool(pages), "pages.pages cannot be empty")
    return {"schema": PAGES_SCHEMA, "rubric": rubric, "pages": pages}


def validate_decisions(value: Any) -> dict[str, Any]:
    data = _object(value, "decisions")
    _require(data.get("schema") == DECISIONS_SCHEMA, "unknown decisions schema")
    rubric = _versioned(data.get("rubric"), "decisions.rubric")
    queries = []
    seen = set()
    for index, raw in enumerate(_list(data.get("queries"), "decisions.queries")):
        query = _object(raw, f"decisions.queries[{index}]")
        required = {"query_id", "query", "source", "evidence_state"}
        allowed = required | {"observed_ranking_url", "offer", "conversion_value", "cost", "sample_size", "lag_days"}
        _require(required <= set(query) <= allowed, "query fields are unsupported")
        query_id = _text(query["query_id"], "query_id")
        _require(query_id not in seen, "query IDs must be unique")
        seen.add(query_id)
        _require(query["evidence_state"] in {"observed", "measured", "suggested", "inferred", "generated"}, "unknown evidence state")
        normalized = {key: _text(query[key], f"query.{key}") for key in ("query_id", "query")}
        normalized["source"] = _source(query["source"], "query.source")
        normalized["evidence_state"] = query["evidence_state"]
        normalized["observed_ranking_url"] = query.get("observed_ranking_url")
        normalized["offer"] = query.get("offer", "")
        for key in ("conversion_value", "cost", "sample_size", "lag_days"):
            metric = query.get(key)
            _require(metric is None or (isinstance(metric, (int, float)) and not isinstance(metric, bool) and metric >= 0), f"{key} is invalid")
            normalized[key] = metric
        queries.append(normalized)
    _require(bool(queries), "decisions.queries cannot be empty")
    return {"schema": DECISIONS_SCHEMA, "rubric": rubric, "queries": queries}


def _score(query: dict[str, Any], page: dict[str, Any]) -> tuple[int, list[str]]:
    terms = _tokens(query["query"])
    title_terms = _tokens(f"{page['title']} {page['h1']}")
    body_terms = _tokens(page["body"])
    matched = sorted(terms & (title_terms | body_terms))
    score = len(terms & title_terms) * 3 + len(terms & body_terms)
    if query["offer"] and _tokens(query["offer"]) <= _tokens(page["offer"]):
        score += 3
    return score, matched


def _intent_key(query: str) -> str:
    return " ".join(sorted(_tokens(query)))


def _priority(query: dict[str, Any]) -> tuple[float, str]:
    value = query["conversion_value"]
    cost = query["cost"]
    sample = query["sample_size"]
    lag = query["lag_days"]
    score = (value or 0) - (cost or 0)
    uncertainty = "unknown" if value is None or sample is None or lag is None else "reported"
    if sample is not None and sample < 30:
        uncertainty = "small_sample"
    if lag is not None and lag > 30:
        uncertainty = "lagged"
    return score, uncertainty


def _candidates(query: dict[str, Any], pages: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], bool]:
    candidates = []
    retrieved_terms = False
    required_terms = _tokens(query["query"])
    offer_terms = _tokens(query["offer"])
    for page in pages:
        score, terms = _score(query, page)
        retrieved_terms = retrieved_terms or bool(terms)
        coverage = len(terms) / len(required_terms) if required_terms else 0
        offer_matches = not offer_terms or offer_terms <= _tokens(page["offer"])
        if score and coverage >= 0.6 and offer_matches:
            candidates.append({"page_id": page["page_id"], "url": page["url"], "score": score, "terms": terms, "source": page["source"]})
    candidates.sort(key=lambda item: (-item["score"], item["page_id"]))
    return candidates[:MAX_CANDIDATES], retrieved_terms


def _match_result(query: dict[str, Any], candidates: list[dict[str, Any]], retrieved_terms: bool) -> dict[str, Any]:
    best = candidates[0]["score"] if candidates else 0
    winners = [item for item in candidates if item["score"] == best]
    status = "abstained"
    reason = "candidate_recall_insufficient" if retrieved_terms else "no_candidate_retrieved"
    if _tokens(query["offer"]) and not candidates:
        reason = "offer_mismatch"
    elif best >= 3 and len(winners) == 1:
        status, reason = "matched", "lexical_and_intent_evidence"
    elif best >= 3:
        status, reason = "multiple", "equivalent_candidate_evidence"
    return {"query_id": query["query_id"], "query": query["query"], "status": status, "reason": reason,
            "observed_ranking_url": query["observed_ranking_url"], "candidates": candidates,
            "source": query["source"], "evidence_state": query["evidence_state"]}


def _add_brief(briefs: dict[str, dict[str, Any]], query: dict[str, Any]) -> None:
    key = _intent_key(query["query"])
    priority, uncertainty = _priority(query)
    existing = briefs.get(key)
    if existing is None:
        briefs[key] = {"intent_key": key, "query_ids": [query["query_id"]], "priority": priority,
                       "uncertainty": uncertainty, "kind": "content_or_landing_brief", "non_mutating": True,
                       "source": query["source"], "reason": "no_suitable_page_evidence"}
        return
    existing["query_ids"].append(query["query_id"])
    existing["priority"] = max(existing["priority"], priority)


def match(pages_data: Any, decisions_data: Any) -> dict[str, Any]:
    pages = validate_pages(pages_data)
    decisions = validate_decisions(decisions_data)
    _require(pages["rubric"] == decisions["rubric"], "page and decision rubric versions must match")
    results = []
    briefs: dict[str, dict[str, Any]] = {}
    for query in decisions["queries"]:
        candidates, retrieved_terms = _candidates(query, pages["pages"])
        result = _match_result(query, candidates, retrieved_terms)
        results.append(result)
        if result["status"] == "abstained":
            _add_brief(briefs, query)
    return {"schema": REPORT_SCHEMA, "rubric": pages["rubric"], "authority": "non_mutating_recommendations_only",
            "retrieval": {"method": "deterministic_lexical", "max_candidates_per_query": MAX_CANDIDATES},
            "results": results, "briefs": sorted(briefs.values(), key=lambda item: (-item["priority"], item["intent_key"]))}
