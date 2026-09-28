#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation rules for context/keywords registries."""

from __future__ import annotations

import re
from pathlib import Path

import keywords_overlap as overlap
import keywords_registry as reg
import keywords_strategy as strategy
import keywords_toon as toon

REFERENCES = [
    ("targets", "cluster_id", "clusters"),
    ("targets", "parent_id", "targets"),
    ("queries", "cluster_id", "clusters"),
    ("queries", "target_id", "targets"),
    ("clusters", "parent_id", "clusters"),
    ("clusters", "pillar_target_id", "targets"),
]


def _numeric_error(field: str, value: str) -> str:
    try:
        number = float(value)
    except ValueError:
        return f"{field} must be numeric, got {value!r}"
    low, high = reg.RANGES.get(field, (number, number))
    return "" if low <= number <= high else f"{field} must be {low}-{high}, got {value}"


def _allowed(table: str, field: str) -> set[str] | None:
    if field == "surface":
        return reg.SURFACES
    if (table, field) == ("entities", "role"):
        return reg.ENTITY_ROLES
    return reg.ENUMS.get(field)


def _check_value(table: str, row_id: str, field: str, value: str) -> list[str]:
    if not value:
        return []
    allowed = _allowed(table, field)
    if field in reg.NUMERIC:
        message = _numeric_error(field, value)
    else:
        message = "" if allowed is None or value in allowed else f"{field} {value!r} not in {sorted(allowed)}"
    return [f"{table} {row_id}: {message}"] if message else []


def _check_rows(table: str, rows: list[dict]) -> list[str]:
    errors: list[str] = []
    prefix = reg.TABLES[table]["prefix"]
    text_field = reg.TABLES[table]["text"]
    seen: set[str] = set()
    for row in rows:
        row_id = row.get("id", "")
        if not re.fullmatch(rf"{prefix}-\d{{4,}}", row_id):
            errors.append(f"{table}: invalid id {row_id!r} (expected {prefix}-0001)")
        if row_id in seen:
            errors.append(f"{table}: duplicate id {row_id}")
        seen.add(row_id)
        if not row.get(text_field):
            errors.append(f"{table} {row_id}: {text_field} is required")
        for field, value in row.items():
            errors.extend(_check_value(table, row_id, field, value))
    return errors


def _dangling(registry: dict, table: str, field: str, target: str) -> list[str]:
    known = {row["id"] for row in registry[target]}
    return [f"{table} {row['id']}: {field} {row[field]} does not exist in {target}"
            for row in registry[table] if row.get(field) and row[field] not in known]


def _modifier_scope(registry: dict) -> list[str]:
    clusters = {row["id"] for row in registry["clusters"]} | {"*"}
    errors = []
    for row in registry["modifiers"]:
        missing = [item for item in reg.split_list(row.get("applies_to", "")) if item not in clusters]
        if missing:
            errors.append(f"modifiers {row['id']}: applies_to unknown clusters {', '.join(missing)}")
    return errors


def _check_references(registry: dict) -> list[str]:
    errors = [error for spec in REFERENCES for error in _dangling(registry, *spec)]
    return errors + _modifier_scope(registry)


def _load_checked(root: Path) -> tuple[dict, list[str]]:
    registry = reg.empty_tables()
    errors: list[str] = []
    for table in reg.TABLES:
        path = reg.table_path(root, table)
        if not path.is_file():
            errors.append(f"missing {path.relative_to(root)}")
            continue
        try:
            registry[table] = reg.load_table(path, table)
        except toon.ToonError as error:
            errors.append(f"{path.relative_to(root)}: {error}")
    return registry, errors


def validate(root: Path) -> dict:
    root = Path(root)
    errors: list[str] = []
    if (root / reg.STRATEGY_FILE).is_file():
        errors += strategy.validate(strategy.load(root))
    else:
        errors.append(f"missing {reg.STRATEGY_FILE}")
    registry, load_errors = _load_checked(root)
    errors += load_errors
    for table, rows in registry.items():
        errors += _check_rows(table, rows)
    errors += _check_references(registry) + overlap.duplicate_phrases(registry) + overlap.duplicate_questions(registry)
    counts = {table: len(rows) for table, rows in registry.items()}
    return {"ok": not errors, "errors": errors, "warnings": overlap.url_warnings(registry), "counts": counts}
