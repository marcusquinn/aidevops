#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Priority scoring and consumer brief slices for keyword registries."""

from __future__ import annotations

import math
from pathlib import Path

import keywords_registry as reg
import keywords_strategy as strategy

WEIGHTS = {"value": 0.45, "opportunity": 0.35, "position": 0.20}
ASSET_GUIDANCE = {
    "image": "File name: slug of the primary phrase plus the subject (e.g. `{slug}-front-view.webp`). "
             "Alt text describes what is visible first; include a phrase only when it is literally true. "
             "Title/caption may carry a secondary phrase. Embed IPTC/XMP keywords and creator/copyright. "
             "Legible text inside images must match nearby copy.",
    "video": "Title leads with the primary phrase in natural words; description opens with the answer; "
             "chapters use cluster siblings and questions; transcript and VideoObject stay consistent.",
    "social": "Bio/profile and post copy use the brand entity name consistently; hashtags come from the "
              "cluster `hashtags` column; one primary phrase per post, written for people first.",
    "pr": "Use the canonical entity name and sameAs targets; associate the brand with the cluster topic; "
          "vary anchor text (brand, URL, natural phrases) and never buy exact-match anchors.",
    "schema": "Organization/Person/Product use entity `same_as`; set `about`/`mentions` from cluster terms; "
              "`knowsAbout` from associations; `areaServed` from markets.",
    "domain": "Prefer the brand entity over exact-match domains; ccTLD only for a single market; keep "
              "pillar phrases in paths, not in the hostname.",
    "product": "Product title order: brand, product type (head phrase), key attributes from modifiers, "
               "variant. Merchant feeds, Product/Offer schema and image file names use the same order.",
    "repo": "GitHub description and README first paragraph answer the primary query; topics come from "
            "cluster phrases (max 20); package keywords mirror them.",
}


def _number(value: str, default: float | None = None) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _opportunity(row: dict) -> float:
    score = _number(row.get("keyword_score", ""))
    if score is not None:
        return score
    volume = _number(row.get("volume", ""), 0.0) or 0.0
    difficulty = _number(row.get("kd", ""), 50.0)
    volume_score = min(100.0, math.log10(volume + 1) / math.log10(100001) * 100)
    return 0.5 * volume_score + 0.5 * (100 - difficulty)


def _position_score(row: dict) -> float:
    position = _number(row.get("last_position", ""))
    if position is None or position <= 0:
        return 30.0
    if position <= 3:
        return 10.0
    if position <= 20:
        return 100.0
    return 60.0 if position <= 30 else 30.0


def priority(row: dict) -> int:
    """Deterministic 0-100 priority: human value, opportunity and striking distance."""
    value = ((_number(row.get("business_value", ""), 3.0) or 3.0) - 1) / 4 * 100
    total = (WEIGHTS["value"] * value + WEIGHTS["opportunity"] * _opportunity(row)
             + WEIGHTS["position"] * _position_score(row))
    return max(0, min(100, round(total)))


def score(registry: dict) -> list[tuple[str, str, str]]:
    changes = []
    for table in ("targets", "queries"):
        for row in registry[table]:
            new = str(priority(row))
            if row.get("priority") != new:
                changes.append((row["id"], row.get("priority", ""), new))
                row["priority"] = new
    return changes


SELECTORS = {"target": "id", "url": "target_url", "cluster": "cluster_id"}


def _by_priority(row: dict) -> float:
    return -(_number(row.get("priority", ""), 0) or 0)


def _select(registry: dict, selector: dict) -> list[dict]:
    targets = registry["targets"]
    for key, field in SELECTORS.items():
        if selector.get(key):
            return [row for row in targets if row.get(field) == selector[key]]
    active = [row for row in targets if row.get("status") != "retired"]
    return sorted(active, key=_by_priority)[:10]


def _line(row: dict) -> str:
    bits = [row.get("role", ""), row.get("classic_intent", ""), f"P{row.get('priority') or '?'}"]
    url = f" -> {row['target_url']}" if row.get("target_url") else ""
    return f"- {row['id']} {row['phrase']} ({', '.join(bit for bit in bits if bit)}){url}"


def _section(title: str, lines: list[str]) -> list[str]:
    return ["", f"## {title}", *lines] if lines else []


def _header(root: Path, front: dict) -> list[str]:
    surfaces = ", ".join(strategy.as_list(front.get("surfaces"))) or "unset"
    locales = ", ".join(strategy.as_list(front.get("locales"))) or "unset"
    return [f"# Search brief: {front.get('name', Path(root).name)}", f"Surfaces: {surfaces} | Locales: {locales}"]


def _asset_lines(selector: dict, primary: list[dict]) -> list[str]:
    guidance = ASSET_GUIDANCE.get(selector.get("asset") or "")
    if not guidance or not primary:
        return []
    return [guidance.replace("{slug}", reg.slugify(primary[0]["phrase"]))]


def _in_clusters(rows: list[dict], clusters: set, exclude: list[dict]) -> list[dict]:
    return [row for row in rows if row.get("cluster_id") in clusters and row not in exclude]


def _entity_line(row: dict) -> str:
    return f"- {row['name']} ({row.get('type', '')}) sameAs: {row.get('same_as', '')}"


def _question_line(row: dict) -> str:
    return f"- {row['id']} {row['question']}"


def brief(root: Path, registry: dict, selector: dict) -> str:
    front = strategy.load(root)
    primary = _select(registry, selector)
    clusters = {row.get("cluster_id") for row in primary} - {"", None}
    siblings = _in_clusters(registry["targets"], clusters, primary)[:15]
    questions = _in_clusters(registry["queries"], clusters, [])[:10]
    entities = [row for row in registry["entities"] if row.get("role") in {"self", "person", "product"}]
    rules = strategy.section(root, "Naming and metadata rules")
    out = _header(root, front)
    out += _section("Primary", list(map(_line, primary)) or ["- none selected"])
    out += _section("Cluster siblings", list(map(_line, siblings)))
    out += _section("Questions", list(map(_question_line, questions)))
    out += _section("Entities", list(map(_entity_line, entities)))
    out += _section("Rules", [rules] * bool(rules))
    out += _section(f"{selector.get('asset')} guidance", _asset_lines(selector, primary))
    return "\n".join(out) + "\n"
