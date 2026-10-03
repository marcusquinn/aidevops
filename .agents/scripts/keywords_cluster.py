#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Modifier drill-down expansion and SERP-overlap clustering."""

from __future__ import annotations

import re
from collections import Counter
from urllib.parse import urlsplit

import keywords_brief as scoring
import keywords_registry as reg

DEFAULT_PATTERNS = {
    "attribute": "{value} {head}",
    "price": "{value} {head}",
    "brand": "{value} {head}",
    "audience": "{head} for {value}",
    "use_case": "{head} for {value}",
    "problem": "{head} for {value}",
    "compatibility": "{head} for {value}",
    "occasion": "{head} for {value}",
    "location": "{head} in {value}",
    "comparison": "{head} vs {value}",
}


def _applies(modifier: dict, cluster_id: str) -> bool:
    scope = reg.split_list(modifier.get("applies_to", "")) or ["*"]
    return modifier.get("status") != "retired" and ("*" in scope or cluster_id in scope)


INHERITED = ("cluster_id", "surface", "locale", "market", "classic_intent")


def _head(registry: dict, head_id: str, min_priority: float, force: bool) -> dict:
    head = reg.find(registry["targets"], head_id)
    if head is None:
        raise KeyError(f"targets: no row {head_id}")
    head_priority = float(head.get("priority") or scoring.priority(head))
    if head_priority < min_priority and not force:
        raise ValueError(f"{head_id} priority {head_priority:.0f} is below drill-down threshold {min_priority:.0f}")
    return head


def _phrase(head: dict, modifier: dict) -> str:
    pattern = modifier.get("pattern") or DEFAULT_PATTERNS.get(modifier.get("dimension", ""), "{head} {value}")
    return re.sub(r"\s+", " ", pattern.format(head=head["phrase"], value=modifier["value"])).strip()


def expand(registry: dict, head_id: str, min_priority: float, force: bool = False) -> list[dict]:
    """Return candidate long-tail rows for one head target (not yet stored)."""
    head = _head(registry, head_id, min_priority, force)
    existing = {reg.normalise_phrase(row.get("phrase", "")) for row in registry["targets"]}
    candidates = []
    for modifier in (item for item in registry["modifiers"] if _applies(item, head.get("cluster_id", ""))):
        phrase = _phrase(head, modifier)
        if reg.normalise_phrase(phrase) in existing:
            continue
        existing.add(reg.normalise_phrase(phrase))
        candidates.append({"phrase": phrase, "role": "longtail", "parent_id": head_id, "status": "candidate",
                           "evidence": f"expand:{modifier['id']}", **{key: head.get(key, "") for key in INHERITED}})
    return candidates


def normalise_url(url: str) -> str:
    parts = urlsplit(url if "//" in url else f"//{url}")
    host = parts.netloc.lower().removeprefix("www.")
    return f"{host}{parts.path.rstrip('/')}"


def _find_root(parents: dict[str, str], item: str) -> str:
    while parents[item] != item:
        parents[item] = parents[parents[item]]
        item = parents[item]
    return item


def overlap_groups(serps: dict[str, list[str]], threshold: int) -> list[list[str]]:
    """Group keywords whose top results share at least `threshold` URLs."""
    urls = {keyword: {normalise_url(url) for url in results} for keyword, results in serps.items()}
    parents = {keyword: keyword for keyword in urls}
    keywords = sorted(urls)
    for index, first in enumerate(keywords):
        for second in keywords[index + 1:]:
            if len(urls[first] & urls[second]) >= threshold:
                parents[_find_root(parents, second)] = _find_root(parents, first)
    groups: dict[str, list[str]] = {}
    for keyword in keywords:
        groups.setdefault(_find_root(parents, keyword), []).append(keyword)
    return sorted(groups.values(), key=lambda group: (-len(group), group[0]))


def _group_cluster(registry: dict, rows: list[dict]) -> str:
    known = Counter(row["cluster_id"] for row in rows if row.get("cluster_id"))
    if known:
        return known.most_common(1)[0][0]
    lead = max(rows, key=lambda row: float(row.get("volume") or 0))
    return reg.add_row(registry, "clusters", {"name": lead["phrase"], "pillar_target_id": lead["id"]})["id"]


def _assign(registry: dict, row: dict, cluster_id: str) -> str:
    current = row.get("cluster_id")
    if current == cluster_id:
        return ""
    if current:
        return f"conflict {row['id']} stays in {current} (overlap suggests {cluster_id})"
    reg.set_fields(registry, "targets", row["id"], {"cluster_id": cluster_id})
    return f"{row['id']} -> {cluster_id}"


def apply_groups(registry: dict, groups: list[list[str]]) -> list[str]:
    """Assign cluster IDs to registry targets from overlap groups; returns report lines."""
    by_phrase = {reg.normalise_phrase(row["phrase"]): row for row in registry["targets"]}
    report: list[str] = []
    for group in groups:
        rows = [by_phrase[key] for key in map(reg.normalise_phrase, group) if key in by_phrase]
        report += _apply_group(registry, rows)
    return report


def _apply_group(registry: dict, rows: list[dict]) -> list[str]:
    if len(rows) < 2:
        return []
    cluster_id = _group_cluster(registry, rows)
    return list(filter(None, (_assign(registry, row, cluster_id) for row in rows)))
