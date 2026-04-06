#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify a worker log file tail for stall diagnosis.

Extracted from the inline heredoc in worker-lifecycle-common.sh
(_collect_worker_stall_evidence) to reduce shell nesting depth (GH#17561).

Arguments (positional):
    argv[1]  - log file path (empty string if no log)
    argv[2]  - number of tail lines to inspect

Prints: "classification<TAB>excerpt" to stdout.
    classification: no_log | no_signal | empty_log | rate_limited |
                    completion_signal | activity_signal
"""

import json
import re
import sys
from collections import deque
from pathlib import Path


def _extract_tool_name(obj):
    """Extract tool name from a log event object."""
    for key in ("tool", "toolName", "name"):
        value = obj.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def _classify_excerpt(excerpt):
    """Classify a log excerpt string into a signal category."""
    if not excerpt:
        return "empty_log"
    lowered = excerpt.lower()
    if any(
        token in lowered
        for token in ["rate limit", "too many requests", "429", "retry after"]
    ):
        return "rate_limited"
    if any(
        token in lowered
        for token in ["full_loop_complete", "pr_url", "worker_done", "exit:0"]
    ):
        return "completion_signal"
    if any(
        token in lowered
        for token in ["tool", "reasoning", "step", "assistant", "apply_patch", "bash"]
    ):
        return "activity_signal"
    return "no_signal"


def _parse_log_line(raw_line):
    """Parse a raw log line into a display string."""
    line = raw_line.strip()
    if not line or not line.startswith("{"):
        return line
    try:
        obj = json.loads(line)
    except Exception:
        return line
    event_type = (
        obj.get("type")
        or obj.get("role")
        or obj.get("finish")
        or obj.get("event")
    )
    summary = obj.get("summary") or {}
    title = summary.get("title") or obj.get("title") or ""
    tool_name = _extract_tool_name(obj)
    parsed = " ".join(part for part in [event_type, title, tool_name] if part)
    return parsed.strip() or line


def main():
    log_file = sys.argv[1] if len(sys.argv) > 1 else ""
    tail_lines = int(sys.argv[2]) if len(sys.argv) > 2 else 8

    classification = "no_log"
    excerpt = ""

    if log_file and Path(log_file).is_file():
        collected = deque(maxlen=max(tail_lines, 1))
        for raw_line in Path(log_file).read_text(errors="ignore").splitlines():
            parsed = _parse_log_line(raw_line)
            if parsed:
                collected.append(parsed)

        excerpt = " || ".join(collected)
        excerpt = re.sub(r"\s+", " ", excerpt).strip()
        excerpt = excerpt[:240]
        classification = _classify_excerpt(excerpt)

    excerpt = excerpt.replace("\t", " ").replace("|", "/")
    print(f"{classification}\t{excerpt}")


if __name__ == "__main__":
    main()
