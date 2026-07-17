#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reduce an OpenCode JSON stream to non-content lifecycle evidence."""

from __future__ import annotations

import json
import sys
from typing import Any


SAFE_TERMINAL_MARKERS = {
    "FULL_LOOP_COMPLETE",
    "POST_PR_HANDOFF",
    "TASK_COMPLETE",
}
SAFE_EVENT_TYPES = {
    "error",
    "step_finish",
    "step_start",
    "text",
    "tool_use",
}
SAFE_TOOL_STATUSES = {"completed", "error", "pending", "running"}
ERROR_PATTERN_GROUPS = (
    ("quota_exceeded", ("insufficient_quota", "credit exhausted", "quota exceeded")),
    ("rate_limit", ("429", "rate limit", "too many requests", "overloaded")),
    ("auth_error", ("401", "403", "authentication", "unauthorized", "token refresh")),
    ("service_unavailable", ("502", "503", "504", "service unavailable", "connection reset")),
    ("session_not_found", ("session not found",)),
    ("project_table_migration", ("table project already exists",)),
    ("timeout", ("timed out", "timeout")),
    ("permission_required", ("permission",)),
)


def classify_error(value: str) -> str | None:
    lowered = value.lower()
    for category, markers in ERROR_PATTERN_GROUPS:
        if any(marker in lowered for marker in markers):
            return category
    return None


def safe_error_marker(category: str) -> str:
    markers = {
        "auth_error": "HTTP 401 authentication error",
        "permission_required": "permission required",
        "project_table_migration": "table project already exists",
        "quota_exceeded": "insufficient_quota",
        "rate_limit": "HTTP 429 rate limit exceeded",
        "service_unavailable": "HTTP 503 service unavailable",
        "session_not_found": "Session not found",
        "timeout": "request timed out",
    }
    return markers.get(category, "private runtime error")


def nested_mapping(value: Any, key: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    nested = value.get(key)
    return nested if isinstance(nested, dict) else {}


def sanitized_runtime_error(raw_line: str) -> dict[str, Any] | None:
    category = classify_error(raw_line)
    if category is None:
        return None
    return {
        "error": safe_error_marker(category),
        "type": "private_runtime_error",
    }


def sanitize_tool_event(part: dict[str, Any]) -> dict[str, Any]:
    sanitized: dict[str, Any] = {"type": "tool_use"}
    state = nested_mapping(part, "state")
    status = state.get("status")
    if isinstance(status, str) and status in SAFE_TOOL_STATUSES:
        sanitized["status"] = status
    if status == "error":
        category = classify_error(str(state.get("error", "")))
        sanitized["error"] = safe_error_marker(category or "runtime_error")
    return sanitized


def sanitize_text_event(part: dict[str, Any]) -> dict[str, Any]:
    sanitized: dict[str, Any] = {"type": "text"}
    text = part.get("text")
    if not isinstance(text, str):
        return sanitized
    stripped = text.strip()
    if stripped in SAFE_TERMINAL_MARKERS:
        sanitized["text"] = stripped
    elif stripped.startswith("BLOCKED:"):
        sanitized["text"] = "BLOCKED"
    return sanitized


def sanitize_json_event(value: Any, raw_line: str) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    event_type = value.get("type")
    if not isinstance(event_type, str) or event_type not in SAFE_EVENT_TYPES:
        return sanitized_runtime_error(raw_line)

    part = nested_mapping(value, "part")
    if event_type == "tool_use":
        return sanitize_tool_event(part)
    if event_type == "text":
        return sanitize_text_event(part)
    sanitized: dict[str, Any] = {"type": event_type}
    if event_type == "error":
        category = classify_error(raw_line)
        sanitized["error"] = safe_error_marker(category or "runtime_error")
    return sanitized


def emit(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":"), sort_keys=True))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    for raw_bytes in sys.stdin.buffer:
        raw_line = raw_bytes.decode("utf-8", errors="replace")
        try:
            parsed: Any = json.loads(raw_line)
        except json.JSONDecodeError:
            sanitized_error = sanitized_runtime_error(raw_line)
            if sanitized_error is not None:
                emit(sanitized_error)
            continue
        sanitized = sanitize_json_event(parsed, raw_line)
        if sanitized is not None:
            emit(sanitized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
