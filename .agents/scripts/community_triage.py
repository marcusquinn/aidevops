#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, non-mutating comment and community-thread triage."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

INPUT_SCHEMA = "aidevops.community-triage-input/v1"
DECISIONS_SCHEMA = "aidevops.community-triage-decisions/v1"
MAX_BYTES = 1_048_576
MAX_ITEMS = 1_000
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_CATEGORIES = {"question", "complaint", "spam", "praise", "buyer_opportunity", "mixed", "unknown"}
_OWNERS = {"support", "content", "human_response_queue", "none"}
_INJECTION = re.compile(r"(?:ignore (?:all )?(?:previous|prior)|system prompt|reveal (?:your )?instructions|\$\()", re.I)


class TriageError(ValueError):
    """Raised for malformed or unsafe offline triage documents."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise TriageError(message)


def _load(path: str | Path) -> dict[str, Any]:
    raw = Path(path).read_bytes()
    _require(len(raw) <= MAX_BYTES, "input exceeds byte budget")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise TriageError("input is not valid JSON") from error
    _require(isinstance(value, dict), "document must be an object")
    return value


def _identifier(value: Any, field: str) -> str:
    _require(isinstance(value, str) and _ID.fullmatch(value) is not None, f"{field} is invalid")
    return value


def _text(value: Any, field: str) -> str:
    _require(isinstance(value, str) and 0 < len(value) <= 10_000, f"{field} is invalid")
    return value


def _digest(item: dict[str, Any]) -> str:
    payload = json.dumps({key: item[key] for key in ("source_id", "text", "version")}, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def validate_input(value: dict[str, Any]) -> list[dict[str, Any]]:
    _require(set(value) == {"schema", "items"} and value["schema"] == INPUT_SCHEMA, "unknown input schema")
    raw_items = value["items"]
    _require(isinstance(raw_items, list) and 0 < len(raw_items) <= MAX_ITEMS, "items are invalid")
    seen: dict[str, str] = {}
    items = []
    for index, raw in enumerate(raw_items):
        _require(isinstance(raw, dict), "item must be an object")
        _require(set(raw) == {"source_id", "platform", "kind", "text", "version", "access_scope"}, "item fields are invalid")
        item = {key: _identifier(raw[key], f"items[{index}].{key}") for key in ("source_id", "platform", "kind", "version", "access_scope")}
        _require(item["kind"] in {"comment", "thread"}, "item kind is invalid")
        item["text"] = _text(raw["text"], f"items[{index}].text")
        fingerprint = _digest(item)
        previous = seen.get(item["source_id"])
        _require(previous in {None, fingerprint}, "edited source must use a new version")
        seen[item["source_id"]] = fingerprint
        item["evidence_digest"] = fingerprint
        items.append(item)
    return items


def validate_decisions(value: dict[str, Any], source_ids: set[str]) -> dict[str, dict[str, Any]]:
    _require(set(value) == {"schema", "decisions"} and value["schema"] == DECISIONS_SCHEMA, "unknown decisions schema")
    raw_decisions = value["decisions"]
    _require(isinstance(raw_decisions, list), "decisions are invalid")
    output = {}
    for index, raw in enumerate(raw_decisions):
        _require(isinstance(raw, dict) and set(raw) == {"source_id", "categories", "owner", "urgency_reason", "proposed_next_step"}, "decision fields are invalid")
        source_id = _identifier(raw["source_id"], f"decisions[{index}].source_id")
        _require(source_id in source_ids and source_id not in output, "decision source is invalid")
        categories = raw["categories"]
        _require(isinstance(categories, list) and 0 < len(categories) <= 3 and set(categories) <= _CATEGORIES, "decision categories are invalid")
        _require(len(categories) == len(set(categories)), "decision categories are duplicated")
        owner = raw["owner"]
        _require(owner in _OWNERS, "decision owner is invalid")
        output[source_id] = {
            "categories": categories, "owner": owner,
            "urgency_reason": _text(raw["urgency_reason"], "urgency_reason"),
            "proposed_next_step": _text(raw["proposed_next_step"], "proposed_next_step"),
        }
    return output


def analyze(input_path: str | Path, decisions_path: str | Path) -> dict[str, Any]:
    """Return evidence-linked queue proposals without sending or moderating anything."""
    items = validate_input(_load(input_path))
    decisions = validate_decisions(_load(decisions_path), {item["source_id"] for item in items})
    results = []
    for item in items:
        supplied = decisions.get(item["source_id"])
        injected = bool(_INJECTION.search(item["text"]))
        if injected:
            result = {"categories": ["unknown"], "owner": "human_response_queue", "urgency_reason": "untrusted_instruction_text", "proposed_next_step": "review_evidence_only"}
        elif supplied is None:
            result = {"categories": ["unknown"], "owner": "human_response_queue", "urgency_reason": "insufficient_context", "proposed_next_step": "request_authorized_review"}
        else:
            result = supplied
        results.append({
            "source_id": item["source_id"], "platform": item["platform"], "kind": item["kind"],
            "access_scope": item["access_scope"], "evidence_digest": item["evidence_digest"],
            "evidence_spans": [item["text"][:240]], "categories": result["categories"],
            "owner": result["owner"], "urgency_reason": result["urgency_reason"],
            "proposed_next_step": result["proposed_next_step"], "external_action": "prohibited",
        })
    return {"schema": "aidevops.community-triage-report/v1", "authority": "non_mutating_recommendations_only", "results": results}
