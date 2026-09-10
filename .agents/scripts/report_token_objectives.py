#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only objective evidence joins for the token-efficiency scorecard."""

from __future__ import annotations

import json
import sqlite3
from collections import Counter
from typing import Any


def unavailable(reason: str) -> dict[str, Any]:
    return {"available": False, "reason": reason, "objective_count": 0, "verified_objective_count": 0, "outcome_counts": {}, "attributable_request_count": 0, "attributable_cost_usd": None, "attributable_tokens": 0, "cost_per_verified_objective_usd": None, "coverage": {"objective_mapping": 0, "verification": 0, "unallocated_attachments": 0, "conflicting_attachments": 0}}


def collect_objective_evidence(conn: sqlite3.Connection, since: str) -> dict[str, Any]:
    """Join explicit objective attachments only; never infer ownership from sessions."""
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if not {"runtime_events", "llm_requests"}.issubset(tables):
        return unavailable("objective/runtime-event tables are unavailable")
    columns = {row[1] for row in conn.execute("PRAGMA table_info(llm_requests)")}
    required = {"id", "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write"}
    if not required.issubset(columns):
        return unavailable("request identifiers or token fields are unavailable")
    outcomes: dict[str, str] = {}
    attachments: dict[str, set[str]] = {}
    shared = 0
    for event_type, payload_json in conn.execute("SELECT event_type, payload_json FROM runtime_events WHERE occurred_at >= ? AND event_type IN ('objective.outcome', 'objective.session.attached') ORDER BY id", (since,)):
        try:
            payload = json.loads(payload_json)
        except (TypeError, json.JSONDecodeError):
            continue
        objective = payload.get("objective_id")
        if not isinstance(objective, str) or not objective:
            continue
        if event_type == "objective.outcome" and payload.get("outcome") in {"verified", "failed", "cancelled", "incomplete", "unknown", "accepted_unverified"}:
            outcomes[objective] = payload["outcome"]
        elif event_type == "objective.session.attached":
            if payload.get("allocation") == "unallocated":
                shared += 1
            elif payload.get("allocation") == "unique" and isinstance(payload.get("request_ids"), list):
                attachments.setdefault(objective, set()).update(str(value) for value in payload["request_ids"])
    closed = {objective for objective, outcome in outcomes.items() if outcome in {"verified", "failed"}}
    owner: dict[str, str] = {}
    conflicts = 0
    for objective in closed:
        for request_id in attachments.get(objective, set()):
            if request_id in owner and owner[request_id] != objective:
                conflicts += 1
            else:
                owner[request_id] = objective
    rows = []
    if owner:
        placeholders = ",".join("?" for _ in owner)
        rows = conn.execute(f"SELECT id, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write FROM llm_requests WHERE id IN ({placeholders})", tuple(owner)).fetchall()
    cost = sum(float(row[1] or 0) for row in rows) if all(row[1] is not None for row in rows) else None
    verified = sum(outcome == "verified" for outcome in outcomes.values())
    return {"available": True, "objective_count": len(outcomes), "verified_objective_count": verified, "outcome_counts": dict(sorted(Counter(outcomes.values()).items())), "attributable_request_count": len(rows), "attributable_cost_usd": round(cost, 6) if cost is not None else None, "attributable_tokens": sum(sum(int(value or 0) for value in row[2:]) for row in rows), "cost_per_verified_objective_usd": round(cost / verified, 6) if cost is not None and verified else None, "coverage": {"objective_mapping": len(owner), "verification": verified, "unallocated_attachments": shared, "conflicting_attachments": conflicts}}
