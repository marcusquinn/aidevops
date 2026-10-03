#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Front matter and section access for context/keywords.md."""

from __future__ import annotations

import re
from pathlib import Path

import keywords_registry as reg

DEFAULTS = {
    "budget_usd_month": "1",
    "data": "auto",
    "thresholds": {"drilldown_min_priority": "60", "facet_min_demand": "50", "facet_min_items": "3"},
}


def _scalar(text: str) -> object:
    text = text.split(" #", 1)[0].strip()
    if text.startswith("[") and text.endswith("]"):
        return [item.strip().strip("'\"") for item in text[1:-1].split(",") if item.strip()]
    return text.strip("'\"")


def parse_front_matter(text: str) -> dict:
    """Parse the flat/one-level-nested YAML front matter the template uses."""
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return {}
    result: dict = {}
    current: dict | None = None
    for line in match.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, value = line.strip().partition(":")
        if line.startswith("  ") and current is not None:
            current[key.strip()] = _scalar(value)
        elif value.strip():
            result[key.strip()] = _scalar(value)
            current = None
        else:
            current = result.setdefault(key.strip(), {})
    return result


def load(root: Path) -> dict:
    path = Path(root) / reg.STRATEGY_FILE
    if not path.is_file():
        return {}
    return parse_front_matter(path.read_text(encoding="utf-8"))


def setting(front: dict, key: str, default: str = "") -> object:
    if key in front:
        return front[key]
    return DEFAULTS.get(key, default)


def threshold(front: dict, key: str) -> float:
    merged = dict(DEFAULTS["thresholds"])
    merged.update(front.get("thresholds") or {})
    try:
        return float(merged.get(key, 0))
    except (TypeError, ValueError):
        return 0.0


def as_list(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    return [item.strip() for item in str(value or "").split(",") if item.strip()]


def section(root: Path, heading: str) -> str:
    """Return the body of a '## heading' section from keywords.md."""
    path = Path(root) / reg.STRATEGY_FILE
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8")
    match = re.search(rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return match.group(1).strip() if match else ""


def validate(front: dict) -> list[str]:
    errors: list[str] = []
    if front.get("schema") != reg.SCHEMA_ID:
        errors.append(f"keywords.md: front matter schema must be {reg.SCHEMA_ID}")
    unknown = [item for item in as_list(front.get("surfaces")) if item not in reg.SURFACES]
    if unknown:
        errors.append(f"keywords.md: unknown surfaces {', '.join(unknown)}")
    if str(setting(front, "data")) not in {"tracked", "ignored", "auto"}:
        errors.append("keywords.md: data must be tracked, ignored or auto")
    try:
        if float(str(setting(front, "budget_usd_month"))) < 0:
            errors.append("keywords.md: budget_usd_month must be >= 0")
    except ValueError:
        errors.append("keywords.md: budget_usd_month must be a number")
    return errors
