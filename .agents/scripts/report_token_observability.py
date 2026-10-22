#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""SQLite observability evidence readers for local token-use reports.

Keep schema compatibility, connection ownership and evidence availability here;
session grouping, token accounting and report rendering belong to the caller.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any


def _connect(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone()
    return row is not None


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    if not _table_exists(conn, table):
        return set()
    return {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})")}


def _mcp_name_from_tool(tool: str, configured_mcps: list[str]) -> str:
    if tool.startswith("mcp_"):
        remainder = tool[4:]
        return remainder.split("_", 1)[0] if remainder else tool
    for name in configured_mcps:
        normalized = name.replace("-", "_")
        if tool.startswith(f"{normalized}_") or tool.startswith(f"{name}_"):
            return name
    return ""


def _observed_parents(obs_db: Path) -> dict[str, str]:
    conn = _connect(obs_db)
    if conn is None:
        return {}
    try:
        columns = _table_columns(conn, "llm_requests")
        if not {"session_id", "parent_session_id"}.issubset(columns):
            return {}
        rows = conn.execute(
            "SELECT session_id, parent_session_id FROM llm_requests "
            "WHERE session_id IS NOT NULL AND parent_session_id IS NOT NULL "
            "AND session_id != '' AND parent_session_id != ''"
        ).fetchall()
        return {
            str(row["session_id"]): str(row["parent_session_id"])
            for row in rows
            if row["session_id"] != row["parent_session_id"]
        }
    finally:
        conn.close()


def _observability_request_rows(
    conn: sqlite3.Connection, columns: set[str], session_ids: list[str]
) -> list[sqlite3.Row]:
    if not session_ids or not {"session_id", "model_id"}.issubset(columns):
        return []
    selected = ["session_id", "model_id"]
    for column in ("cost", "parent_session_id", "agent"):
        if column in columns:
            selected.append(column)
    placeholders = ",".join("?" for _ in session_ids)
    query = "SELECT " + ", ".join(selected) + " FROM llm_requests WHERE session_id IN (" + placeholders + ")"
    return conn.execute(query, session_ids).fetchall()


def _add_observability_request(result: dict[str, Any], row: sqlite3.Row, columns: set[str]) -> float:
    if row["model_id"]:
        result["models"].add(str(row["model_id"]))
    result["requests"] += 1
    if "parent_session_id" in columns and row["parent_session_id"]:
        result["has_lineage"] = True
    if "agent" in columns:
        result["has_compaction_evidence"] = True
        if "compact" in str(row["agent"] or "").lower():
            result["compaction_session_ids"].add(str(row["session_id"]))
    return float(row["cost"] or 0) if "cost" in columns else 0.0


def _observability_for(obs_db: Path, session_ids: list[str], configured_mcps: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "models": set(),
        "requests": 0,
        "tool_calls": 0,
        "observed_mcps": set(),
        "cost_usd": None,
        "compaction_session_ids": set(),
        "has_lineage": False,
        "has_compaction_evidence": False,
    }
    conn = _connect(obs_db)
    if conn is None:
        return result
    try:
        placeholders = ",".join("?" for _ in session_ids)
        columns = _table_columns(conn, "llm_requests")
        request_rows = _observability_request_rows(conn, columns, session_ids)
        costs = [_add_observability_request(result, row, columns) for row in request_rows]
        if "cost" in columns and request_rows:
            result["cost_usd"] = round(sum(costs), 6)
        if placeholders and _table_exists(conn, "tool_calls"):
            for row in conn.execute(
                f"SELECT tool_name, COUNT(*) AS n FROM tool_calls WHERE session_id IN ({placeholders}) GROUP BY tool_name",
                session_ids,
            ):
                tool = str(row["tool_name"] or "")
                result["tool_calls"] += int(row["n"] or 0)
                mcp_name = _mcp_name_from_tool(tool, configured_mcps)
                if mcp_name:
                    result["observed_mcps"].add(mcp_name)
    finally:
        conn.close()
    return result
