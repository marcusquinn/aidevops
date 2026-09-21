#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Normalize bounded Google SERP observations into Reddit opportunities."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

INPUT_SCHEMA = "aidevops.prospecting-serp/v1"
REPORT_SCHEMA = "aidevops.prospecting-seo-report/v1"


class SeoError(ValueError):
    """Raised when SERP evidence is malformed or cannot be safely compared."""


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SeoError(f"{field} must be a non-empty string")
    return value.strip()


def _canonical_reddit_url(value: str) -> str | None:
    parsed = urlparse(value)
    host = parsed.netloc.lower().removeprefix("www.")
    parts = [part for part in parsed.path.split("/") if part]
    if host not in {"reddit.com", "redd.it"}:
        return None
    if host == "redd.it" and parts:
        return f"https://reddit.com/comments/{parts[0]}"
    if len(parts) >= 3 and parts[0] == "r" and parts[2] == "comments":
        return "https://reddit.com/" + "/".join(parts[:5])
    if len(parts) >= 2 and parts[0] == "comments":
        return "https://reddit.com/" + "/".join(parts[:3])
    return None


def _rank(item: dict[str, Any], index: int) -> int:
    value = item.get("position", index)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise SeoError("result.position must be a positive integer")
    return value


def _observation(run: dict[str, Any], item: dict[str, Any], index: int) -> dict[str, Any] | None:
    original_url = _text(item.get("url"), "result.url")
    canonical_url = _canonical_reddit_url(original_url)
    if canonical_url is None:
        return None
    return {
        "query_id": _text(run.get("query_id"), "query_id"),
        "query": _text(run.get("query"), "query"),
        "observed_at": _text(run.get("observed_at"), "observed_at"),
        "provider": _text(run.get("provider", "fixture"), "provider"),
        "engine": _text(run.get("engine", "google"), "engine"),
        "locale": run.get("locale", "unknown"), "language": run.get("language", "unknown"),
        "device": run.get("device", "unknown"), "result_depth": run.get("result_depth", len(run.get("results", []))),
        "query_mode": run.get("query_mode", "organic"), "rank": _rank(item, index),
        "url": canonical_url, "original_url": original_url, "title": item.get("title", ""),
        "snippet": item.get("snippet", ""), "thread": item.get("thread", {}),
    }


def refresh(value: dict[str, Any]) -> dict[str, Any]:
    """Return only observed Reddit results; failures and depth limits stay explicit."""
    if not isinstance(value, dict) or value.get("schema") != INPUT_SCHEMA:
        raise SeoError(f"input schema must be {INPUT_SCHEMA}")
    runs = value.get("runs")
    if not isinstance(runs, list) or not runs:
        raise SeoError("runs must be a non-empty array")
    observations: list[dict[str, Any]] = []
    incomplete: list[dict[str, str]] = []
    for run in runs:
        if not isinstance(run, dict):
            raise SeoError("run must be an object")
        query_id = _text(run.get("query_id"), "query_id")
        _text(run.get("query"), "query")
        _text(run.get("observed_at"), "observed_at")
        status = run.get("status", "complete")
        if status != "complete":
            incomplete.append({"query_id": query_id, "status": str(status), "reason": "not_compared_as_rank_loss"})
            continue
        results = run.get("results")
        if not isinstance(results, list):
            raise SeoError("complete run.results must be an array")
        for index, item in enumerate(results, 1):
            if not isinstance(item, dict):
                raise SeoError("result must be an object")
            observation = _observation(run, item, index)
            if observation:
                observations.append(observation)
    observations.sort(key=lambda item: (item["query_id"], item["observed_at"], item["rank"], item["url"]))
    history: dict[tuple[str, str, str, str], list[dict[str, Any]]] = {}
    for item in observations:
        cohort = (item["query_id"], item["locale"], item["language"], item["device"])
        history.setdefault(cohort, []).append(item)
    opportunities = []
    for cohort, entries in history.items():
        newest = entries[-1]
        ranks = [entry["rank"] for entry in entries if entry["query_mode"] == "organic" and entry["url"] == newest["url"]]
        thread = newest["thread"] if isinstance(newest["thread"], dict) else {}
        opportunities.append({
            "opportunity_id": "reddit:" + hashlib.sha256((newest["query_id"] + newest["url"]).encode()).hexdigest()[:16],
            "query_id": newest["query_id"], "query": newest["query"], "url": newest["url"],
            "original_url": newest["original_url"], "rank": newest["rank"], "query_mode": newest["query_mode"],
            "rank_scope": "global_organic" if newest["query_mode"] == "organic" else "filtered_discovery_only",
            "history": [{"observed_at": entry["observed_at"], "rank": entry["rank"]} for entry in entries if entry["url"] == newest["url"]],
            "rank_change": ranks[-1] - ranks[0] if len(ranks) > 1 else None,
            "thread": {"age": thread.get("age", "unknown"), "activity": thread.get("activity", "unknown"), "state": thread.get("state", "unknown"), "competitor_mentions": thread.get("competitor_mentions", [])},
            "claims": {"reply_rank_conversion": "not_measured", "ai_citation": "not_measured", "roi": "not_measured"},
        })
    return {"schema": REPORT_SCHEMA, "authority": "observed_search_results_only", "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "observations": observations, "opportunities": opportunities, "incomplete_runs": incomplete}


def load_input(path: str | Path) -> dict[str, Any]:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SeoError("SERP input must be readable JSON") from error
