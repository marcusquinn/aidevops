#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, non-mutating staged community discovery pipeline."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from prospecting_collectors import CollectorError, capability_result

SCHEMA = "aidevops.prospecting-scan/v1"


class ScanError(ValueError):
    """Raised for malformed scan input."""


def _id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ScanError(f"{field} must be a non-empty string")
    return value.strip()


def _quote(text: str) -> str:
    return text[:240]


def _lead_id(provider: str, object_id: str) -> str:
    return "lead:" + hashlib.sha256(f"{provider}:{object_id}".encode()).hexdigest()[:16]


def load_input(path: str | Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ScanError("scan input must be readable JSON") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise ScanError(f"scan input schema must be {SCHEMA}")
    return value


def _normalized_capabilities(value: dict[str, Any]) -> dict[str, dict[str, Any]]:
    capabilities = value.get("capabilities")
    if not isinstance(capabilities, dict):
        raise ScanError("capabilities must be an object")
    return {name: capability_result(name, payload) for name, payload in capabilities.items()}


def _candidate_leads(source: dict[str, Any], rules: dict[Any, dict[str, Any]]) -> list[dict[str, Any]]:
    provider = _id(source.get("provider", "reddit"), "candidate.provider")
    object_id = _id(source.get("id"), "candidate.id")
    community = _id(source.get("community"), "candidate.community")
    policy = rules.get(community, {"community": community, "status": "unavailable"})
    leads: list[dict[str, Any]] = []
    for comment in source.get("comments", []):
        if not isinstance(comment, dict) or comment.get("deleted"):
            continue
        decision = comment.get("decision", {})
        if not isinstance(decision, dict) or not decision.get("buyer_ask", False):
            continue
        comment_id = _id(comment.get("id"), "comment.id")
        text = _id(comment.get("text"), "comment.text")
        leads.append({
            "lead_id": _lead_id(provider, comment_id), "provider": provider,
            "object_id": comment_id, "parent_object_id": object_id,
            "quote": _quote(text), "reason": _id(decision.get("reason"), "decision.reason"),
            "community": community, "community_policy": policy,
            "thread_status": source.get("status", "available"), "external_action": "prohibited",
        })
    return leads


def _triage_candidates(normalized: dict[str, dict[str, Any]], budget: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]], int]:
    rules = {item.get("community"): item for item in normalized.get("rules", {}).get("items", []) if isinstance(item, dict)}
    seen: set[tuple[str, str]] = set()
    leads: list[dict[str, Any]] = []
    unread: list[dict[str, Any]] = []
    calls = 0
    candidates = normalized.get("search", {}).get("items", []) + normalized.get("community", {}).get("items", [])
    for source in candidates:
        if not isinstance(source, dict):
            raise ScanError("candidate must be an object")
        provider = _id(source.get("provider", "reddit"), "candidate.provider")
        object_id = _id(source.get("id"), "candidate.id")
        key = (provider, object_id)
        if key in seen:
            continue
        seen.add(key)
        title = _id(source.get("title"), "candidate.title")
        relevant = bool(source.get("title_relevant", False))
        if not relevant:
            continue
        if calls >= budget:
            unread.append({"provider": provider, "object_id": object_id, "reason": "budget_exhausted", "title": title})
            continue
        calls += 1
        leads.extend(_candidate_leads(source, rules))
    return leads, unread, calls


def scan(value: dict[str, Any]) -> dict[str, Any]:
    """Triage titles first, preserving every incomplete or unavailable window."""
    project_id = _id(value.get("project_id"), "project_id")
    budget = value.get("budget", 0)
    if isinstance(budget, bool) or not isinstance(budget, int) or budget < 0:
        raise ScanError("budget must be a non-negative integer")
    normalized = _normalized_capabilities(value)
    leads, unread, calls = _triage_candidates(normalized, budget)
    coverage = []
    for name, result in normalized.items():
        complete = result["status"] == "available" and result["next_cursor"] is None
        coverage.append({"capability": name, "status": result["status"], "complete": complete, "next_cursor": result["next_cursor"]})
    return {"schema": "aidevops.prospecting-scan-report/v1", "project_id": project_id,
            "authority": "read_only_collection", "cost_receipt": {"budget": budget, "calls": calls},
            "coverage": coverage, "unread": unread, "leads": leads}
