#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Migrate legacy seomachine context files into the keyword registry."""

from __future__ import annotations

import re
from pathlib import Path

import keywords_markdown as md
import keywords_registry as reg

ROLE_LABELS = {"pillar keyword": "pillar", "cluster keywords": "cluster", "long-tail variations": "longtail"}
META_LABELS = {"user job / desired outcome": "user_job", "classic search intent": "classic_intent",
               "journey state": "journey_state", "trend state": "trend_state"}
BULLET_RE = re.compile(r"^- \*\*(?P<label>[^*]+)\*\*:\s*(?P<value>.+)$")


def _meta_value(field: str, value: str) -> str:
    if field == "user_job":
        return value
    value = value.strip().lower()
    return value if value in reg.ENUMS.get(field, {value}) else ""


def _apply_bullet(cluster: dict, label: str, value: str) -> None:
    if label in ROLE_LABELS:
        parsed = [md.parse_item(item) for item in md.split_items(value)]
        cluster["targets"] += [{**item, "role": ROLE_LABELS[label]} for item in parsed
                               if not md.placeholder(item["phrase"])]
    elif label in META_LABELS and not md.placeholder(value):
        cluster["meta"][META_LABELS[label]] = _meta_value(META_LABELS[label], value)


def _parse_clusters(text: str) -> list[dict]:
    clusters: list[dict] = []
    for line in text.splitlines():
        if line.startswith("### "):
            clusters.append({"name": line[4:].strip(), "targets": [], "meta": {}})
            continue
        match = BULLET_RE.match(line.strip())
        if match and clusters:
            _apply_bullet(clusters[-1], match.group("label").strip().lower(), match.group("value").strip())
    return [cluster for cluster in clusters if cluster["targets"] and not md.placeholder(cluster["name"])]


def _find_phrase(registry: dict, phrase: str) -> dict | None:
    key = reg.normalise_phrase(phrase)
    return next((row for row in registry["targets"] if reg.normalise_phrase(row["phrase"]) == key), None)


def _add_target(registry: dict, cluster_id: str, target: dict, meta: dict) -> None:
    if _find_phrase(registry, target["phrase"]) is not None:
        return
    row = reg.add_row(registry, "targets", {**meta, **target, "cluster_id": cluster_id, "status": "targeted",
                                            "evidence": "migrate:legacy"})
    cluster = reg.find(registry["clusters"], cluster_id)
    if target["role"] == "pillar" and cluster is not None and not cluster.get("pillar_target_id"):
        cluster["pillar_target_id"] = row["id"]


def _apply_rankings(registry: dict, text: str) -> int:
    rows = md.table_rows(text, "keyword")
    for cells in rows:
        phrase, position, url = (cells + ["", "", ""])[:3]
        row = _find_phrase(registry, phrase) or reg.add_row(
            registry, "targets", {"phrase": phrase, "status": "targeted", "evidence": "migrate:rankings"})
        row["last_position"] = re.sub(r"[^\d.]", "", position)
        row["ranking_url"] = "" if md.placeholder(url) else url
    return len(rows)


def _migrate_competitors(registry: dict, path: Path) -> int:
    rows = md.table_rows(path.read_text(encoding="utf-8"), "competitor") if path.is_file() else []
    for cells in rows:
        name, domain = (cells + ["", ""])[:2]
        reg.add_row(registry, "entities", {"name": name, "role": "competitor", "type": "Organization",
                                           "same_as": "" if md.placeholder(domain) else f"https://{domain}",
                                           "evidence": "migrate:competitor-analysis"})
    return len(rows)


def migrate(root: Path, registry: dict) -> dict:
    """Merge legacy context files into `registry` (in place); never deletes sources."""
    root = Path(root)
    summary = {"clusters": 0, "targets": 0, "rankings": 0, "competitors": 0}
    legacy = root / reg.LEGACY_FILE
    if legacy.is_file():
        text = legacy.read_text(encoding="utf-8")
        before = len(registry["targets"])
        for cluster in _parse_clusters(text):
            cluster_id = reg.add_row(registry, "clusters", {"name": cluster["name"]})["id"]
            summary["clusters"] += 1
            for target in cluster["targets"]:
                _add_target(registry, cluster_id, target, cluster["meta"])
        summary["targets"] = len(registry["targets"]) - before
        summary["rankings"] = _apply_rankings(registry, text)
    summary["competitors"] = _migrate_competitors(registry, root / "context/competitor-analysis.md")
    return summary
