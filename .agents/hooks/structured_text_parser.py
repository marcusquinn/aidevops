#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Structured text parsing for transcript scrub hooks."""

import json


def parse_structured_text(value: str):
    """Parse complete JSON or independent NDJSON records for recursive scrubbing."""
    parsed = _parse_json_document(value)
    if parsed is not None:
        return parsed, lambda scrubbed: json.dumps(scrubbed, separators=(",", ":"))
    records = []
    for line in value.splitlines():
        record = _parse_json_document(line) if line.strip() else None
        records.append(line if record is None and line.strip() else record)
    if not any(isinstance(record, (dict, list)) for record in records):
        return None
    return records, lambda scrubbed: "\n".join(_stringify_record(record) for record in scrubbed)


def _parse_json_document(value: str):
    """Return JSON containers and leave scalar or invalid values unparsed."""
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, (dict, list)) else None


def _stringify_record(record) -> str:
    """Serialize one parsed record or preserve one raw NDJSON line."""
    if record is None:
        return ""
    if isinstance(record, str):
        return record
    return json.dumps(record, separators=(",", ":"))
