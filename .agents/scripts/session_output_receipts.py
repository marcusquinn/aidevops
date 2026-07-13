#!/usr/bin/env python3
"""Parse compact output receipts without retaining their evidence content."""

from __future__ import annotations

import json
import re


OUTPUT_ID_RE = re.compile(r"(?m)^output_id: out_[A-Za-z0-9_]+$")
EVIDENCE_BYTES_RE = re.compile(r"(?m)^evidence: bytes=([0-9]+)\b")


def _json_receipt_bytes(output: str) -> int | None:
    candidate = output.lstrip()
    if not candidate.startswith("{"):
        return None
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict) or payload.get("schema") != "aidevops.operation-result/v1":
        return None
    evidence = payload.get("evidence")
    if not isinstance(evidence, dict) or not isinstance(evidence.get("bytes"), int):
        return None
    return evidence["bytes"]


def receipt_background_bytes(output: str) -> int | None:
    json_bytes = _json_receipt_bytes(output)
    if json_bytes is not None:
        return json_bytes
    if "output_id: out_" not in output or OUTPUT_ID_RE.search(output) is None:
        return None
    match = EVIDENCE_BYTES_RE.search(output)
    return int(match.group(1)) if match else None
