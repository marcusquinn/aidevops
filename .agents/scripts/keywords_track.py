#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Rank and visibility observations for registry targets and queries.

Free sources: existing GSC/Bing/DataForSEO export files, GitHub repository
search, npm registry search. Paid source: DataForSEO ranked keywords, gated by
the monthly budget ledger. AI answers: imported captures only.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

import keywords_registry as reg
import keywords_store as store

EXPORT_PLATFORMS = {"gsc": "google", "dataforseo": "google", "bing": "bing"}
DFS_URL = "https://api.dataforseo.com/v3/dataforseo_labs/google/ranked_keywords/live"


def _observation(target: dict, platform: str, source: str, **values: str) -> dict:
    row = dict.fromkeys(store.OBS_FIELDS, "")
    row.update({"observed_at": store.now(), "target_id": target.get("id", ""), "phrase": target.get("phrase", ""),
                "platform": platform, "surface": "organic", "locale": target.get("locale", ""),
                "source": source, "status": "complete"})
    row.update(values)
    return row


def _phrase_index(registry: dict) -> dict[str, dict]:
    return {reg.normalise_phrase(row["phrase"]): row for row in registry["targets"] if row.get("status") != "retired"}


def read_export(path: Path) -> tuple[str, list[dict]]:
    """Parse seo-export-*.sh files: key<TAB>value header, '---', TSV table."""
    source, rows, header = "", [], None
    in_table = False
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not in_table:
            key, _, value = line.partition("\t")
            source = value.strip() if key == "source" else source
            in_table = line.strip() == "---"
            continue
        cells = line.split("\t")
        if header is None:
            header = cells
        elif len(cells) == len(header):
            rows.append(dict(zip(header, cells)))
    return source, rows


def from_export(registry: dict, path: Path) -> tuple[list[dict], list[dict]]:
    """Return (matched observations, unmatched export rows) for one export file."""
    source, rows = read_export(path)
    platform = EXPORT_PLATFORMS.get(source, source or "google")
    index = _phrase_index(registry)
    matched, unmatched = [], []
    for row in rows:
        target = index.get(reg.normalise_phrase(row.get("query", "")))
        if target is None:
            unmatched.append(row)
            continue
        matched.append(_observation(target, platform, source or "export", position=row.get("position", ""),
                                    url=row.get("page", "")))
    return matched, unmatched


def default_surface(surfaces: list[str]) -> str:
    """Surface assumed for targets without one: the website, else the first non-AI surface."""
    if "website" in surfaces:
        return "website"
    return next((item for item in surfaces if item != "ai-answers"), "")


def _surface_targets(registry: dict, surface: str, surfaces: list[str], limit: int) -> list[dict]:
    fallback = default_surface(surfaces)
    rows = [row for row in registry["targets"]
            if row.get("status") != "retired" and (row.get("surface") or fallback) == surface]
    return sorted(rows, key=lambda row: -float(row.get("priority") or 0))[:limit]


def _gh_search(phrase: str) -> list[str]:
    result = subprocess.run(["gh", "api", "-X", "GET", "search/repositories", "-f", f"q={phrase}",
                             "-f", "per_page=100", "--jq", ".items[].full_name"],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"gh search failed: {result.stderr.strip()[:200]}")
    return [line.lower() for line in result.stdout.splitlines()]


def github(registry: dict, slug: str, surfaces: list[str], limit: int = 20, pause: float = 2.2) -> list[dict]:
    """Position of `slug` in GitHub repository search (0 = not in top 100)."""
    rows = []
    for target in _surface_targets(registry, "github", surfaces, limit):
        names = _gh_search(target["phrase"])
        position = names.index(slug.lower()) + 1 if slug.lower() in names else 0
        rows.append(_observation(target, "github", "github-search", position=str(position),
                                 url=f"https://github.com/{slug}" if position else ""))
        time.sleep(pause)
    return rows


def _http_json(url: str, data: bytes | None = None, headers: dict | None = None) -> dict:
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError(f"refusing non-https tracker URL: {url}")
    request = urllib.request.Request(url, data=data, headers=headers or {})
    # Scheme is restricted to https above.
    with urllib.request.urlopen(request, timeout=60) as response:  # nosec B310
        return json.loads(response.read().decode("utf-8"))


def npm(registry: dict, package: str, surfaces: list[str], limit: int = 20) -> list[dict]:
    """Position of `package` in npm registry search (0 = not in top 250)."""
    rows = []
    for target in _surface_targets(registry, "npm", surfaces, limit):
        query = urllib.parse.urlencode({"text": target["phrase"], "size": 250})
        payload = _http_json(f"https://registry.npmjs.org/-/v1/search?{query}")
        names = [item["package"]["name"] for item in payload.get("objects", [])]
        position = names.index(package) + 1 if package in names else 0
        rows.append(_observation(target, "npm", "npm-search", position=str(position),
                                 url=f"https://www.npmjs.com/package/{package}" if position else ""))
    return rows


def _dfs_auth() -> str:
    user, password = os.environ.get("DATAFORSEO_USERNAME", ""), os.environ.get("DATAFORSEO_PASSWORD", "")
    if not user or not password:
        raise RuntimeError("DATAFORSEO_USERNAME/DATAFORSEO_PASSWORD are not set (aidevops secret set ...)")
    return base64.b64encode(f"{user}:{password}".encode()).decode()


def _dfs_items(payload: dict) -> list[dict]:
    task = (payload.get("tasks") or [{}])[0]
    result = (task.get("result") or [{}])[0] or {}
    return result.get("items") or []


def _dfs_observations(registry: dict, items: list[dict]) -> list[dict]:
    index = _phrase_index(registry)
    rows = []
    for item in items:
        target = index.get(reg.normalise_phrase(item.get("keyword_data", {}).get("keyword", "")))
        serp = item.get("ranked_serp_element", {}).get("serp_item", {})
        if target is not None:
            rows.append(_observation(target, "google", "dataforseo", position=str(serp.get("rank_absolute", "")),
                                     url=serp.get("url", "")))
    return rows


def dataforseo(registry: dict, prop: str, front: dict, domain: str, estimate: float) -> tuple[list[dict], str]:
    """Budget-gated ranked-keywords call for one domain; returns (observations, ledger message)."""
    allowed, message = store.check_budget(prop, front, estimate)
    if not allowed:
        return [], message
    body = json.dumps([{"target": domain, "location_code": int(front.get("location_code") or 2840),
                        "language_code": str(front.get("language_code") or "en"), "limit": 1000}]).encode()
    headers = {"Authorization": f"Basic {_dfs_auth()}", "Content-Type": "application/json"}
    try:
        payload = _http_json(DFS_URL, body, headers)
    except (OSError, ValueError):
        # Count the estimate so a failing provider cannot bypass the monthly cap.
        store.record_spend(prop, {"provider": "dataforseo", "operation": "ranked_keywords", "estimate_usd": estimate,
                                  "cost_usd": None, "note": f"{domain} (request failed)"})
        raise
    cost = payload.get("cost")
    store.record_spend(prop, {"provider": "dataforseo", "operation": "ranked_keywords", "estimate_usd": estimate,
                              "cost_usd": cost, "note": domain})
    return _dfs_observations(registry, _dfs_items(payload)), f"{message}; recorded cost {cost}"


def _flag(value: bool) -> str:
    return "true" if value else "false"


def _capture_row(observation: dict, query: dict, brands: list[str], domains: list[str]) -> dict:
    entities = [entity for entity in observation["entities"] if entity["brand"] in brands]
    urls = [citation["url"] for citation in observation["citations"]]
    cited = any(domain in url for url in urls for domain in domains if domain)
    return {**dict.fromkeys(store.OBS_FIELDS, ""), "observed_at": observation["captured_at"],
            "query_id": query["id"], "phrase": query["question"], "platform": observation["engine"],
            "surface": observation["mode"], "locale": observation["locale"], "source": "ai-captures",
            "mentioned": _flag(bool(entities)), "recommended": _flag(any(item["recommended"] for item in entities)),
            "cited": _flag(cited), "status": observation["status"]}


def ai_captures(registry: dict, captures: dict, brands: list[str], domains: list[str]) -> list[dict]:
    """Code approved AI-answer captures against queries using ai_visibility."""
    import ai_visibility  # local sibling module

    report = ai_visibility.analyze(captures, {"brands": brands})
    by_question = {reg.normalise_phrase(row["question"]): row for row in registry["queries"]}
    matched = [(observation, by_question.get(reg.normalise_phrase(observation["prompt"])))
               for observation in report["observations"]]
    return [_capture_row(observation, query, brands, domains) for observation, query in matched if query]
