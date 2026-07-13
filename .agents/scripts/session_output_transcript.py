#!/usr/bin/env python3
"""Privacy-preserving transcript extraction for session output analysis."""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ToolResult:
    tool: str
    input_value: str
    output: str
    success: bool | None


def canonical(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def safe_tool_name(value: Any) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value or "unknown")).strip("-")
    return sanitized[:48] or "unknown"


def _opencode_success(state: dict[str, Any]) -> bool:
    metadata = state.get("metadata")
    if isinstance(metadata, dict) and isinstance(metadata.get("exit"), int):
        return metadata["exit"] == 0
    return True


def result_from_opencode_part(part: dict[str, Any]) -> ToolResult | None:
    if part.get("type") != "tool":
        return None
    state = part.get("state")
    if not isinstance(state, dict) or state.get("status") != "completed":
        return None
    return ToolResult(
        tool=safe_tool_name(part.get("tool")),
        input_value=canonical(state.get("input", {})),
        output=canonical(state.get("output", "")),
        success=_opencode_success(state),
    )


def _embedded_part(record: dict[str, Any]) -> dict[str, Any] | None:
    data = record.get("data")
    if isinstance(data, dict):
        return data
    if not isinstance(data, str):
        return None
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _normalized_result(record: dict[str, Any]) -> ToolResult | None:
    if "tool" not in record or "output" not in record:
        return None
    success_value = record.get("success")
    success = success_value if isinstance(success_value, bool) else None
    return ToolResult(
        tool=safe_tool_name(record.get("tool")),
        input_value=canonical(record.get("input", {})),
        output=canonical(record.get("output", "")),
        success=success,
    )


def _direct_result(record: dict[str, Any]) -> ToolResult | None:
    embedded = _embedded_part(record)
    if embedded is not None:
        result = result_from_opencode_part(embedded)
        if result is not None:
            return result
    result = result_from_opencode_part(record)
    return result if result is not None else _normalized_result(record)


def _claude_content(record: dict[str, Any]) -> list[dict[str, Any]]:
    message = record.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [item for item in content if isinstance(item, dict)]


def _claude_results(
    content: list[dict[str, Any]],
    tool_uses: dict[str, tuple[str, str]],
) -> list[ToolResult]:
    results: list[ToolResult] = []
    for item in content:
        item_type = item.get("type")
        call_id = str(item.get("id") or item.get("tool_use_id") or "")
        if item_type == "tool_use" and call_id:
            tool_uses[call_id] = (
                safe_tool_name(item.get("name")),
                canonical(item.get("input", {})),
            )
        elif item_type == "tool_result":
            tool, input_value = tool_uses.get(call_id, ("unknown", "{}"))
            results.append(
                ToolResult(
                    tool=tool,
                    input_value=input_value,
                    output=canonical(item.get("content", "")),
                    success=not bool(item.get("is_error", False)),
                )
            )
    return results


def extract_jsonl(path: Path) -> tuple[list[ToolResult], int]:
    results: list[ToolResult] = []
    parse_errors = 0
    tool_uses: dict[str, tuple[str, str]] = {}
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                parse_errors += 1
                continue
            if not isinstance(record, dict):
                continue
            direct = _direct_result(record)
            if direct is not None:
                results.append(direct)
                continue
            results.extend(_claude_results(_claude_content(record), tool_uses))
    return results, parse_errors


def resolve_jsonl(source: Path, session_id: str) -> Path:
    if source.is_file():
        return source
    if not source.is_dir():
        raise ValueError("transcript source is unavailable")
    if not session_id:
        raise ValueError("--session is required when the transcript source is a directory")
    exact = source / f"{session_id}.jsonl"
    if exact.is_file():
        return exact
    matches = sorted(source.rglob(f"{session_id}.jsonl"))
    if not matches:
        matches = sorted(source.rglob(f"*{session_id}*.jsonl"))
    if not matches:
        raise ValueError("session transcript was not found")
    return matches[0]


def extract_opencode_db(path: Path, session_id: str) -> tuple[list[ToolResult], int]:
    if not session_id:
        raise ValueError("--session is required for an OpenCode database")
    if not path.is_file():
        raise ValueError("OpenCode database is unavailable")
    results: list[ToolResult] = []
    parse_errors = 0
    row_count = 0
    uri = f"file:{path}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute(
            "SELECT data FROM part WHERE session_id = ? ORDER BY time_created, id",
            (session_id,),
        )
        for (raw_data,) in rows:
            row_count += 1
            try:
                part = json.loads(raw_data)
            except (TypeError, json.JSONDecodeError):
                parse_errors += 1
                continue
            if isinstance(part, dict):
                result = result_from_opencode_part(part)
                if result is not None:
                    results.append(result)
    if row_count == 0:
        raise ValueError("session transcript was not found")
    return results, parse_errors
