#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline, evidence-preserving marketing snapshot import normalization."""

from __future__ import annotations

import csv
import hashlib
import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


class ImportError(ValueError):
    """Raised when an import cannot be safely normalized."""


SUPPORTED_KINDS = {"google-ads", "meta", "gsc", "site", "ai-capture", "community"}


def _decimal(value: Any, field: str) -> str | None:
    if value in (None, ""):
        return None
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise ImportError(f"{field} is not a decimal") from error
    if not parsed.is_finite() or parsed < 0:
        raise ImportError(f"{field} must be non-negative")
    return format(parsed, "f")


def _integer(value: Any, field: str) -> int | None:
    decimal = _decimal(value, field)
    if decimal is None:
        return None
    parsed = Decimal(decimal)
    if parsed != parsed.to_integral_value():
        raise ImportError(f"{field} must be an integer")
    return int(parsed)


def _source_hash(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def _identity(row: dict[str, Any], fallback: int) -> str:
    """Return a source-provided row identity or the stable row position."""
    for field in ("id", "ID", "query", "Query"):
        value = row.get(field)
        if value not in (None, ""):
            return str(value)
    return str(fallback)


def _read_rows(kind: str, path: Path) -> tuple[list[dict[str, Any]], dict[str, str]]:
    if kind == "google-ads":
        try:
            with path.open(newline="", encoding="utf-8-sig") as source:
                reader = csv.DictReader(source)
                if not reader.fieldnames:
                    raise ImportError("CSV header is required")
                return list(reader), {name: name for name in reader.fieldnames}
        except csv.Error as error:
            raise ImportError("CSV is malformed") from error
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ImportError("JSON is malformed") from error
    rows = document.get("rows") if isinstance(document, dict) else document
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise ImportError("JSON must contain an array of object rows")
    columns = {name: name for row in rows for name in row}
    return rows, columns


def normalize(kind: str, source: str | Path, context: dict[str, str | None] | None = None) -> dict[str, Any]:
    """Normalize a local CSV/JSON export without mutating its raw evidence."""
    if kind not in SUPPORTED_KINDS:
        raise ImportError("unsupported import kind")
    path = Path(source)
    if not path.is_file() or path.is_symlink():
        raise ImportError("input must be a regular file")
    rows, column_mapping = _read_rows(kind, path)
    records: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    identities: set[str] = set()
    for index, row in enumerate(rows, 1):
        identity = _identity(row, index)
        if not identity or identity in identities:
            errors.append({"row": index, "reason": "missing_or_conflicting_id", "raw": row})
            continue
        identities.add(identity)
        try:
            currency = row.get("currency") or row.get("Currency")
            micros = _integer(row.get("cost_micros") or row.get("Cost micros"), "cost_micros")
            amount = _decimal(row.get("spend") or row.get("cost") or row.get("Cost"), "spend")
            if micros is not None and amount is not None:
                raise ImportError("ambiguous spend units")
            records.append({
                "id": identity,
                "raw": row,
                "metrics": {
                    "clicks": _integer(row.get("clicks") or row.get("Clicks"), "clicks"),
                    "impressions": _integer(row.get("impressions") or row.get("Impressions"), "impressions"),
                    "spend_micros": micros,
                    "spend": amount,
                    "currency": currency if isinstance(currency, str) and len(currency) == 3 else None,
                    "refunds": _decimal(row.get("refunds"), "refunds"),
                    "conversions": _decimal(row.get("conversions") or row.get("Conversions"), "conversions"),
                    "conversion_value": _decimal(row.get("conversion_value"), "conversion_value"),
                },
                "query_coverage": row.get("query_coverage") or row.get("Query coverage") or "unknown",
                "attribution_window": row.get("attribution_window"),
            })
        except ImportError as error:
            errors.append({"row": index, "reason": str(error), "raw": row})
    context = context or {}
    return {
        "schema": "aidevops.marketing-snapshot-import/v1",
        "kind": kind,
        "source": {"name": path.name, "sha256": _source_hash(path), "column_mapping": column_mapping},
        "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "scope": context.get("scope"),
        "date_start": context.get("date_start"),
        "date_end": context.get("date_end"),
        "timezone": context.get("timezone"),
        "currency": context.get("currency"),
        "records": records,
        "row_errors": errors,
        "unknown_metrics": sorted({key for row in rows for key in row} - set(column_mapping)),
    }
