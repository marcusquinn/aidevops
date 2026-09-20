#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Provider-neutral, offline coding for AI visibility observations."""

from __future__ import annotations

import re
from collections import Counter, defaultdict
from typing import Any

URL_RE = re.compile(r"https?://[^\s)\]>,]+", re.IGNORECASE)
SOURCE_TYPES = {"news": "news", "review": "review", "directory": "directory", "documentation": "documentation"}
POSITIVE_RE = re.compile(r"\b(best|excellent|reliable|strong|recommended)\b", re.IGNORECASE)
NEGATIVE_RE = re.compile(r"\b(avoid|poor|weak|expensive|not recommended)\b", re.IGNORECASE)


class VisibilityError(ValueError):
    """Raised when supplied observations cannot be safely coded."""


def _require(value: bool, message: str) -> None:
    if not value:
        raise VisibilityError(message)


def _source_type(url: str) -> str:
    lowered = url.lower()
    return next((kind for token, kind in SOURCE_TYPES.items() if token in lowered), "web")


def _sentiment(text: str) -> str:
    positive, negative = bool(POSITIVE_RE.search(text)), bool(NEGATIVE_RE.search(text))
    if positive and not negative:
        return "positive"
    if negative and not positive:
        return "negative"
    return "mixed" if positive else "neutral"


def _brand_context(answer: str, brand: str) -> str:
    sentences = re.split(r"(?<=[.!?])\s+", answer)
    return " ".join(sentence for sentence in sentences if brand.casefold() in sentence.casefold())


def _is_recommended(context: str, brand: str) -> bool:
    """Require a recommendation cue attached to this brand, not another entity."""
    escaped = re.escape(brand)
    return bool(re.search(rf"\b(recommend|choose|consider|top pick)\s+(?:the\s+)?{escaped}\b", context, re.IGNORECASE))


def normalize_capture(raw: Any) -> dict[str, Any]:
    """Normalize one supplied capture without asserting unobserved engine details."""
    _require(isinstance(raw, dict), "capture must be an object")
    required = {"capture_id", "engine", "prompt", "cohort", "captured_at", "status"}
    _require(required <= set(raw), "capture is missing required fields")
    _require(raw["status"] in {"complete", "failed", "unavailable"}, "capture status is unsupported")
    for field in required - {"status"}:
        _require(isinstance(raw[field], str) and raw[field], f"capture.{field} must be a non-empty string")
    answer = raw.get("answer")
    _require(answer is None or isinstance(answer, str), "capture.answer must be a string or null")
    if raw["status"] == "complete":
        _require(answer is not None, "complete capture requires an answer")
    return {
        "capture_id": raw["capture_id"], "engine": raw["engine"], "product": raw.get("product", raw["engine"]),
        "model": raw.get("model", "unknown"), "mode": raw.get("mode", "unknown"),
        "locale": raw.get("locale", "unknown"), "language": raw.get("language", "unknown"),
        "session_context": raw.get("session_context", "unknown"), "prompt": raw["prompt"], "cohort": raw["cohort"],
        "captured_at": raw["captured_at"], "status": raw["status"], "answer": answer or "", "source_id": raw.get("source_id", raw["capture_id"]),
        "failure_reason": raw.get("failure_reason"),
    }


def analyze(document: Any, decisions: Any) -> dict[str, Any]:
    """Code supplied answers; failed and unavailable captures never enter valid denominators."""
    _require(isinstance(document, dict) and isinstance(document.get("captures"), list), "input requires captures")
    _require(isinstance(decisions, dict) and isinstance(decisions.get("brands"), list), "decisions requires brands")
    brands = decisions["brands"]
    _require(brands and all(isinstance(brand, str) and brand for brand in brands), "brands must be non-empty strings")
    captures = [normalize_capture(capture) for capture in document["captures"]]
    _require(len({capture["capture_id"] for capture in captures}) == len(captures), "capture IDs must be unique")
    observations = []
    for capture in captures:
        answer = capture["answer"]
        citations = sorted({url.rstrip(".") for url in URL_RE.findall(answer)}) if capture["status"] == "complete" else []
        entities = []
        for brand in brands:
            context = _brand_context(answer, brand)
            if context:
                entities.append({"brand": brand, "mentioned": True, "recommended": _is_recommended(context, brand), "sentiment": _sentiment(context)})
        observations.append({**capture, "citations": [{"url": url, "source_type": _source_type(url)} for url in citations], "entities": entities})
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for observation in observations:
        groups[(observation["engine"], observation["mode"], observation["cohort"])].append(observation)
    lines = []
    for (engine, mode, cohort), rows in sorted(groups.items()):
        valid = [row for row in rows if row["status"] == "complete"]
        mentions = Counter(entity["brand"] for row in valid for entity in row["entities"])
        recommendations = Counter(entity["brand"] for row in valid for entity in row["entities"] if entity["recommended"])
        source_types = Counter(citation["source_type"] for row in valid for citation in row["citations"])
        lines.append({"engine": engine, "mode": mode, "cohort": cohort, "captures": len(rows), "valid_answers": len(valid), "failed": sum(row["status"] == "failed" for row in rows), "unavailable": sum(row["status"] == "unavailable" for row in rows), "completion_coverage": len(valid) / len(rows) if rows else 0, "mentions": dict(sorted(mentions.items())), "recommendations": dict(sorted(recommendations.items())), "citation_count": sum(len(row["citations"]) for row in valid), "source_types": dict(sorted(source_types.items())), "repeat_variation": "unavailable" if len(valid) < 2 else "observe per-capture rows"})
    return {"schema": "aidevops.ai-visibility-report/v1", "authority": "offline_observation_only", "collection": "imported_captures_only", "observations": observations, "engine_mode_cohort_lines": lines, "aggregate": {"status": "component_tables_first", "engine_lines": len(lines), "valid_answers": sum(line["valid_answers"] for line in lines), "captures": len(captures)}}
