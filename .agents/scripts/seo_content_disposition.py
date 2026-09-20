#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, evidence-preserving content disposition proposals."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

PAGES_SCHEMA = "aidevops.content-disposition-pages/v1"
DECISIONS_SCHEMA = "aidevops.content-disposition-decisions/v1"
REPORT_SCHEMA = "aidevops.content-disposition-report/v1"
TOKEN_RE = re.compile(r"[a-z0-9]+")
OUTCOMES = {"keep", "update", "merge", "remove", "abstain"}


class DispositionError(ValueError):
    """Raised when review evidence is incomplete or unsafe."""


def _require(value: bool, message: str) -> None:
    if not value:
        raise DispositionError(message)


def _object(value: Any, name: str) -> dict[str, Any]:
    _require(isinstance(value, dict), f"{name} must be an object")
    return value


def _text(value: Any, name: str) -> str:
    _require(isinstance(value, str) and value.strip(), f"{name} must be a non-empty string")
    return value.strip()


def _tokens(value: str) -> set[str]:
    return set(TOKEN_RE.findall(value.lower()))


def _digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def validate_pages(value: Any) -> dict[str, Any]:
    data = _object(value, "pages")
    _require(data.get("schema") == PAGES_SCHEMA, "unknown pages schema")
    pages = []
    seen = set()
    for index, raw in enumerate(data.get("pages", [])):
        page = _object(raw, f"pages[{index}]")
        required = {"page_id", "url", "title", "visible_text", "intent", "status"}
        optional = {"word_count", "backlinks", "traffic", "conversions", "freshness", "protected", "canonical_facts", "structured_data", "replacement_url"}
        _require(required <= set(page) <= required | optional, "page contains unsupported fields")
        page_id = _text(page["page_id"], "page_id")
        _require(page_id not in seen, "page IDs must be unique")
        seen.add(page_id)
        _require(page["status"] in {200, 301, 302, 404, 410}, "page status is unsupported")
        normalized = {key: _text(page[key], key) for key in ("page_id", "url", "title", "visible_text", "intent")}
        normalized.update({"status": page["status"], "word_count": page.get("word_count", len(_tokens(page["visible_text"]))),
                           "backlinks": page.get("backlinks"), "traffic": page.get("traffic"), "conversions": page.get("conversions"),
                           "freshness": page.get("freshness"), "protected": bool(page.get("protected", False)),
                           "canonical_facts": page.get("canonical_facts", []), "structured_data": page.get("structured_data", []),
                           "replacement_url": page.get("replacement_url")})
        _require(all(metric is None or isinstance(metric, (int, float)) and not isinstance(metric, bool) and metric >= 0
                     for metric in (normalized["backlinks"], normalized["traffic"], normalized["conversions"])), "metrics must be non-negative or null")
        _require(isinstance(normalized["canonical_facts"], list) and isinstance(normalized["structured_data"], list), "facts and structured data must be arrays")
        pages.append(normalized)
    _require(bool(pages), "pages cannot be empty")
    return {"schema": PAGES_SCHEMA, "pages": pages}


def validate_decisions(value: Any) -> dict[str, Any]:
    data = _object(value, "decisions")
    _require(data.get("schema") == DECISIONS_SCHEMA, "unknown decisions schema")
    outcomes = _object(data.get("outcomes"), "outcomes")
    _require(set(outcomes) == set(), "outcomes must start empty")
    return {"schema": DECISIONS_SCHEMA, "outcomes": outcomes}


def _schema_findings(page: dict[str, Any]) -> list[dict[str, str]]:
    visible = " ".join([page["title"], page["visible_text"], *page["canonical_facts"]]).lower()
    findings = []
    for item in page["structured_data"]:
        if not isinstance(item, dict):
            findings.append({"kind": "syntax", "state": "invalid", "detail": "structured data item is not an object"})
            continue
        claim = item.get("claim")
        if not isinstance(claim, str) or not claim.strip():
            findings.append({"kind": "syntax", "state": "invalid", "detail": "claim is missing"})
        elif claim.lower() not in visible:
            findings.append({"kind": "visible_consistency", "state": "mismatch", "detail": claim})
        else:
            findings.append({"kind": "factual_verification", "state": "unresolved", "detail": claim})
    return findings


def _candidate(page: dict[str, Any], pages: list[dict[str, Any]]) -> tuple[dict[str, Any] | None, str]:
    requested = page["replacement_url"]
    if requested == page["url"]:
        return None, "redirect_loop"
    candidates = [other for other in pages if other["page_id"] != page["page_id"] and other["status"] == 200]
    if requested:
        candidates = [other for other in candidates if other["url"] == requested]
        if not candidates:
            return None, "replacement_not_live"
    scores = [(len(_tokens(page["intent"]) & _tokens(other["intent"])), other) for other in candidates]
    scores = [item for item in scores if item[0]]
    if not scores:
        return None, "no_replacement"
    scores.sort(key=lambda item: (-item[0], item[1]["page_id"]))
    target = scores[0][1]
    if target["url"] == page["url"] or target["status"] != 200 or target["replacement_url"]:
        return None, "unsafe_target"
    return {"from": page["url"], "to": target["url"], "target_page_id": target["page_id"], "confidence": "heuristic", "non_mutating": True}, "candidate_retrieved"


def review(pages_data: Any, decisions_data: Any) -> dict[str, Any]:
    pages = validate_pages(pages_data)["pages"]
    validate_decisions(decisions_data)
    results = []
    proposed_targets: set[str] = set()
    for page in pages:
        evidence = {"purpose": page["intent"], "backlinks": page["backlinks"], "traffic": page["traffic"], "conversions": page["conversions"],
                    "freshness": page["freshness"], "protected": page["protected"], "word_count": page["word_count"]}
        outcome, reason = "abstain", "missing_demand_evidence"
        proposal = None
        if page["protected"]:
            outcome, reason = "keep", "protected_page"
        elif page["status"] == 410:
            outcome, reason = "remove", "retired_page_confirmed"
        elif page["traffic"] is None or page["conversions"] is None:
            outcome, reason = "abstain", "missing_demand_evidence"
        elif page["word_count"] < 120 and page["backlinks"] == 0 and page["traffic"] == 0 and page["conversions"] == 0:
            proposal, candidate_reason = _candidate(page, pages)
            if proposal and proposal["target_page_id"] in proposed_targets:
                proposal, outcome, reason = None, "update", "many_to_one_requires_review"
            elif proposal:
                proposed_targets.add(proposal["target_page_id"])
                outcome, reason = "merge", candidate_reason
            else:
                outcome, reason = "update", candidate_reason
        elif page["word_count"] < 300:
            outcome, reason = "update", "useful_short_content_requires_review"
        else:
            outcome, reason = "keep", "sufficient_evidence"
        results.append({"page_id": page["page_id"], "outcome": outcome, "reason": reason, "evidence": evidence,
                        "migration_proposal": proposal, "schema_findings": _schema_findings(page), "non_mutating": True})
    return {"schema": REPORT_SCHEMA, "authority": "non_mutating_recommendations_only", "input_digest": _digest(pages_data),
            "results": results, "decisions_written": False}
