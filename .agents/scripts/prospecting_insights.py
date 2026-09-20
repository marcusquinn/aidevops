#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Derive non-mutating, evidence-linked prospecting insight snapshots."""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

INPUT_SCHEMA = "aidevops.prospecting-insights-input/v1"
DECISIONS_SCHEMA = "aidevops.prospecting-insights-decisions/v1"
REPORT_SCHEMA = "aidevops.prospecting-insights-report/v1"
MAX_BYTES = 1_048_576
MAX_ITEMS = 1_000
MAX_QUOTE = 240
VALID_KINDS = {"post", "comment", "thread"}
VALID_SIGNALS = {"mention", "recommendation", "comparison", "complaint"}
VALID_SENTIMENT = {"positive", "negative", "mixed", "neutral", "unknown"}


class InsightError(ValueError):
    """Raised when an offline insight document cannot preserve its contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise InsightError(message)


def _load(path: str | Path) -> dict[str, Any]:
    raw = Path(path).read_bytes()
    _require(len(raw) <= MAX_BYTES, "document exceeds byte budget")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise InsightError("document is not valid JSON") from error
    _require(isinstance(value, dict), "document must be an object")
    return value


def _text(value: Any, field: str, *, maximum: int = 10_000) -> str:
    _require(isinstance(value, str) and 0 < len(value) <= maximum, f"{field} is invalid")
    return value


def _digest(value: dict[str, Any]) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(raw.encode()).hexdigest()


def validate_input(value: dict[str, Any]) -> list[dict[str, Any]]:
    _require(set(value) == {"schema", "snapshot_id", "as_of", "rubric_version", "observations"}, "input fields are invalid")
    _require(value["schema"] == INPUT_SCHEMA, "unknown input schema")
    _text(value["snapshot_id"], "snapshot_id", maximum=128)
    _text(value["as_of"], "as_of", maximum=64)
    _text(value["rubric_version"], "rubric_version", maximum=128)
    raw_items = value["observations"]
    _require(isinstance(raw_items, list) and 0 <= len(raw_items) <= MAX_ITEMS, "observations are invalid")
    seen: dict[str, str] = {}
    items: list[dict[str, Any]] = []
    for index, raw in enumerate(raw_items):
        _require(isinstance(raw, dict) and set(raw) == {"source_id", "thread_id", "kind", "observed_at", "access_scope", "text"}, "observation fields are invalid")
        item = {key: _text(raw[key], f"observations[{index}].{key}", maximum=128) for key in ("source_id", "thread_id", "observed_at", "access_scope")}
        item["kind"] = _text(raw["kind"], f"observations[{index}].kind", maximum=32)
        _require(item["kind"] in VALID_KINDS, "observation kind is invalid")
        item["text"] = _text(raw["text"], f"observations[{index}].text")
        fingerprint = _digest(item)
        previous = seen.get(item["source_id"])
        _require(previous in {None, fingerprint}, "edited source must use a new source_id")
        seen[item["source_id"]] = fingerprint
        item["evidence_digest"] = fingerprint
        if previous is None:
            items.append(item)
    return items


def validate_decisions(value: dict[str, Any], source_ids: set[str]) -> dict[str, dict[str, Any]]:
    _require(set(value) == {"schema", "decisions"} and value["schema"] == DECISIONS_SCHEMA, "unknown decisions schema")
    _require(isinstance(value["decisions"], list), "decisions are invalid")
    output: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(value["decisions"]):
        _require(isinstance(raw, dict) and set(raw) == {"source_id", "competitors", "themes", "stage", "classification_status"}, "decision fields are invalid")
        source_id = _text(raw["source_id"], f"decisions[{index}].source_id", maximum=128)
        _require(source_id in source_ids and source_id not in output, "decision source is invalid")
        _require(raw["classification_status"] in {"complete", "partial", "failed"}, "classification status is invalid")
        _require(raw["stage"] in {"aware", "considering", "evaluating", "unknown"}, "stage is invalid")
        competitors, themes = raw["competitors"], raw["themes"]
        _require(isinstance(competitors, list) and isinstance(themes, list), "decision lists are invalid")
        checked_competitors = []
        for item in competitors:
            _require(isinstance(item, dict) and set(item) == {"entity", "aliases", "signal", "sentiment", "target", "span", "quoted"}, "competitor fields are invalid")
            entity = _text(item["entity"], "competitor entity", maximum=128)
            aliases = item["aliases"]
            _require(isinstance(aliases, list) and all(isinstance(alias, str) and alias for alias in aliases), "competitor aliases are invalid")
            _require(item["signal"] in VALID_SIGNALS and item["sentiment"] in VALID_SENTIMENT, "competitor signal is invalid")
            _require(isinstance(item["target"], bool) and isinstance(item["quoted"], bool), "competitor flags are invalid")
            checked_competitors.append({**item, "entity": entity, "span": _text(item["span"], "competitor span", maximum=MAX_QUOTE)})
        checked_themes = []
        for item in themes:
            _require(isinstance(item, dict) and set(item) == {"theme", "span", "target"}, "theme fields are invalid")
            _require(isinstance(item["target"], bool), "theme target is invalid")
            checked_themes.append({"theme": _text(item["theme"], "theme", maximum=128), "span": _text(item["span"], "theme span", maximum=MAX_QUOTE), "target": item["target"]})
        output[source_id] = {"competitors": checked_competitors, "themes": checked_themes, "stage": raw["stage"], "classification_status": raw["classification_status"]}
    return output


def _summary(rows: dict[str, list[dict[str, Any]]], label: str) -> list[dict[str, Any]]:
    result = []
    for name, evidence in sorted(rows.items()):
        sources = {row["source_id"] for row in evidence}
        threads = {row["thread_id"] for row in evidence}
        result.append({label: name, "observation_count": len(sources), "thread_count": len(threads), "evidence": evidence[:5]})
    return result


def derive(input_path: str | Path, decisions_path: str | Path) -> dict[str, Any]:
    raw_input = _load(input_path)
    items = validate_input(raw_input)
    decisions = validate_decisions(_load(decisions_path), {item["source_id"] for item in items})
    competitors: dict[str, list[dict[str, Any]]] = defaultdict(list)
    themes: dict[str, list[dict[str, Any]]] = defaultdict(list)
    stages: dict[str, int] = defaultdict(int)
    classified = {"complete": 0, "partial": 0, "failed": 0, "unclassified": 0}
    for item in items:
        decision = decisions.get(item["source_id"])
        if decision is None:
            classified["unclassified"] += 1
            continue
        classified[decision["classification_status"]] += 1
        stages[decision["stage"]] += 1
        evidence = {key: item[key] for key in ("source_id", "thread_id", "kind", "observed_at", "access_scope", "evidence_digest")}
        for competitor in decision["competitors"]:
            # Quoted speech remains evidence but never becomes an author recommendation/sentiment claim.
            competitors[competitor["entity"]].append({**evidence, "aliases": competitor["aliases"], "signal": competitor["signal"], "sentiment": "unknown" if competitor["quoted"] else competitor["sentiment"], "target": competitor["target"], "quoted": competitor["quoted"], "span": competitor["span"]})
        for theme in decision["themes"]:
            themes[theme["theme"]].append({**evidence, "target": theme["target"], "span": theme["span"]})
    dates = sorted(item["observed_at"] for item in items)
    return {
        "schema": REPORT_SCHEMA,
        "authority": "non_mutating_evidence_linked_insights_only",
        "snapshot": {key: raw_input[key] for key in ("snapshot_id", "as_of", "rubric_version")},
        "coverage": {"observation_count": len(items), "thread_count": len({item["thread_id"] for item in items}), "date_window": [dates[0], dates[-1]] if dates else None, "classification": classified},
        "competitors": _summary(competitors, "entity"),
        "pain_themes": _summary(themes, "theme"),
        "buyer_stages": dict(sorted(stages.items())),
        "comparison": {"available": False, "reason": "baseline_snapshot_not_supplied"},
        "handoffs": {"content_product_opportunities": "evidence_only_not_market_demand", "outreach": "prohibited", "targeting": "prohibited", "raw_evidence_mutation": "prohibited"},
    }


def compare(baseline_path: str | Path, current_path: str | Path) -> dict[str, Any]:
    """Compare compatible derived snapshots without inferring demand or causality."""
    baseline, current = _load(baseline_path), _load(current_path)
    for report in (baseline, current):
        _require(report.get("schema") == REPORT_SCHEMA, "unknown report schema")
        _require(isinstance(report.get("snapshot"), dict) and isinstance(report.get("coverage"), dict), "report is invalid")
    baseline_rubric = baseline["snapshot"].get("rubric_version")
    current_rubric = current["snapshot"].get("rubric_version")
    if baseline_rubric != current_rubric:
        return {"schema": REPORT_SCHEMA, "comparison": {"available": False, "reason": "rubric_version_mismatch", "baseline_rubric_version": baseline_rubric, "current_rubric_version": current_rubric}}
    def counts(report: dict[str, Any], key: str, label: str) -> dict[str, int]:
        rows = report.get(key, [])
        _require(isinstance(rows, list), "report summaries are invalid")
        return {row[label]: row["observation_count"] for row in rows if isinstance(row, dict) and isinstance(row.get(label), str) and isinstance(row.get("observation_count"), int)}
    def delta(key: str, label: str) -> dict[str, int]:
        old, new = counts(baseline, key, label), counts(current, key, label)
        return {name: new.get(name, 0) - old.get(name, 0) for name in sorted(set(old) | set(new))}
    return {"schema": REPORT_SCHEMA, "comparison": {"available": True, "rubric_version": current_rubric, "baseline": {"snapshot_id": baseline["snapshot"].get("snapshot_id"), "coverage": baseline["coverage"]}, "current": {"snapshot_id": current["snapshot"].get("snapshot_id"), "coverage": current["coverage"]}, "competitor_observation_delta": delta("competitors", "entity"), "pain_theme_observation_delta": delta("pain_themes", "theme"), "interpretation": "coverage_bound_observation_change_not_market_demand"}}
