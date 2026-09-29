#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Schema, storage and write operations for context/keywords registries."""

from __future__ import annotations

import datetime as _dt
import re
import unicodedata
from pathlib import Path

import keywords_toon as toon

SCHEMA_ID = "aidevops.keywords/v1"
STRATEGY_FILE = "context/keywords.md"
TABLE_DIR = "context/keywords"
LEGACY_FILE = "context/target-keywords.md"

TABLES: dict[str, dict] = {
    "targets": {"prefix": "k", "text": "phrase", "fields": [
        "id", "phrase", "role", "parent_id", "cluster_id", "surface", "locale", "market",
        "classic_intent", "journey_state", "user_job", "business_value", "volume", "kd", "cpc",
        "keyword_score", "priority", "trend_state", "target_url", "status", "channels", "evidence",
        "ranking_url", "last_position", "best_position", "trend", "last_checked", "updated"]},
    "queries": {"prefix": "q", "text": "question", "fields": [
        "id", "question", "cluster_id", "target_id", "locale", "market", "engines", "journey_state",
        "query_form", "grounding_likelihood", "business_value", "priority", "target_url", "status",
        "mention_rate", "citation_rate", "last_checked", "evidence", "updated"]},
    "clusters": {"prefix": "c", "text": "name", "fields": [
        "id", "name", "parent_id", "pillar_target_id", "target_url", "page_type", "taxonomy",
        "anchors", "terms", "authors", "schema_types", "hashtags", "updated"]},
    "modifiers": {"prefix": "m", "text": "value", "fields": [
        "id", "dimension", "value", "pattern", "applies_to", "demand", "page_policy", "status", "updated"]},
    "entities": {"prefix": "e", "text": "name", "fields": [
        "id", "name", "type", "role", "same_as", "associations", "evidence", "updated"]},
}

NUMERIC = {"business_value", "volume", "kd", "cpc", "keyword_score", "priority", "last_position",
           "best_position", "mention_rate", "citation_rate", "demand"}

SURFACES = {"website", "ecommerce", "github", "npm", "pypi", "homebrew", "crates", "app-store",
            "play-store", "chrome-web-store", "wordpress-org", "marketplace", "youtube", "social",
            "ai-answers", "local"}

ENUMS: dict[str, set[str]] = {
    "role": {"pillar", "cluster", "longtail", "brand", "product", "category"},
    "status": {"candidate", "targeted", "live", "won", "retired", "active"},
    "classic_intent": {"informational", "navigational", "commercial", "transactional"},
    "journey_state": {"discover", "understand", "evaluate", "act", "use-resolve", "monitor"},
    "trend_state": {"evergreen", "seasonal", "rising", "event-driven", "decaying", "uncertain"},
    "query_form": {"question", "command", "comparison", "recommendation", "definition", "how-to", "troubleshooting"},
    "grounding_likelihood": {"high", "medium", "low"},
    "page_type": {"collection", "category", "product", "article", "landing", "docs", "tool", "faq",
                  "comparison", "location", "repo", "package"},
    "dimension": {"attribute", "audience", "use_case", "problem", "compatibility", "occasion",
                  "location", "price", "brand", "comparison"},
    "page_policy": {"collection", "facet-index", "facet-noindex", "section", "faq", "attribute-only", "none"},
    "type": {"Organization", "Person", "Product", "Brand", "SoftwareApplication", "Place", "LocalBusiness",
             "CreativeWork", "Thing", "Event", "Service"},
    "trend": {"up", "down", "flat", "new", "lost"},
}
ENTITY_ROLES = {"self", "competitor", "partner", "person", "product", "topic", "place"}
RANGES = {"business_value": (1, 5), "kd": (0, 100), "keyword_score": (0, 100), "priority": (0, 100),
          "mention_rate": (0, 1), "citation_rate": (0, 1)}


def today() -> str:
    return _dt.date.today().isoformat()


def slugify(text: str) -> str:
    """ASCII, lowercase, hyphenated slug for URLs, files and anchors."""
    normal = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", normal.lower()).strip("-")


def normalise_phrase(text: str) -> str:
    return re.sub(r"\s+", " ", text.casefold()).strip()


def table_path(root: Path, table: str) -> Path:
    return Path(root) / TABLE_DIR / f"{table}.toon"


def empty_tables() -> dict[str, list[dict]]:
    return {name: [] for name in TABLES}


def load_table(path: Path, table: str) -> list[dict]:
    if not path.is_file():
        return []
    parsed = toon.load(path)
    data = parsed["tables"].get(table)
    return [] if data is None else data["rows"]


def load_registry(root: Path) -> dict[str, list[dict]]:
    return {name: load_table(table_path(root, name), name) for name in TABLES}


def save_table(path: Path, table: str, rows: list[dict]) -> None:
    fields = TABLES[table]["fields"]
    extra = [key for row in rows for key in row if key not in fields]
    ordered = fields + list(dict.fromkeys(extra))
    toon.dump(path, {"schema": SCHEMA_ID}, [(table, ordered, rows)], NUMERIC)


def save_registry(root: Path, registry: dict[str, list[dict]]) -> None:
    for name, rows in registry.items():
        save_table(table_path(root, name), name, rows)


def next_id(rows: list[dict], table: str) -> str:
    prefix = TABLES[table]["prefix"]
    numbers = [int(match.group(1)) for row in rows
               if (match := re.fullmatch(rf"{prefix}-(\d+)", row.get("id", "")))]
    return f"{prefix}-{(max(numbers) if numbers else 0) + 1:04d}"


def find(rows: list[dict], row_id: str) -> dict | None:
    return next((row for row in rows if row.get("id") == row_id), None)


def add_row(registry: dict, table: str, values: dict[str, str]) -> dict:
    """Append a row with a fresh ID; returns the stored row."""
    rows = registry[table]
    row = {field: "" for field in TABLES[table]["fields"]}
    row.update({key: value for key, value in values.items() if key != "id"})
    row["id"] = values.get("id") or next_id(rows, table)
    row["updated"] = values.get("updated") or today()
    if table in ("targets", "queries") and not row.get("status"):
        row["status"] = "candidate"
    rows.append(row)
    return row


def set_fields(registry: dict, table: str, row_id: str, values: dict[str, str]) -> dict:
    row = find(registry[table], row_id)
    if row is None:
        raise KeyError(f"{table}: no row {row_id}")
    row.update(values)
    row["updated"] = today()
    return row


def parse_assignments(pairs: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise ValueError(f"expected field=value, got {pair!r}")
        key, value = pair.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def split_list(value: str) -> list[str]:
    return [item.strip() for item in (value or "").split(";") if item.strip()]
