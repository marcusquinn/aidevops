#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Pre-edit complexity advisory hook for Claude Code (PreToolUse hook).

Inspects Edit and Write tool calls for bash function definitions in newString.
Emits an advisory (not a block) when a proposed function body exceeds 80 lines —
the 40% buffer below the 100-line function-complexity CI gate.

Always returns permissionDecision="allow". The advisory text in the reason
field is shown to the user so they can decompose proactively before writing code
that will later fail the complexity gate.

Installed by: install-hooks-helper.sh
Location: ~/.aidevops/hooks/complexity_advisory_pre_edit.py
Configured in: ~/.claude/settings.json (hooks.PreToolUse)

Scope: *.sh, *.bash, *.zsh files only. All other file types are silently skipped.

Threshold: 80 lines (COMPLEXITY_WARN_THRESHOLD) — configurable via env var.

Exit behavior:
  - Exit 0 with JSON {"hookSpecificOutput": {"permissionDecision": "allow", "reason": "..."}} = advisory
  - Exit 0 with no output = allow silently
"""
import json
import os
import re
import sys
from typing import Generator

# Advisory fires when a function body is projected to exceed this many lines.
# Configurable via AIDEVOPS_COMPLEXITY_WARN_THRESHOLD env var.
_DEFAULT_THRESHOLD = 80
COMPLEXITY_WARN_THRESHOLD = int(
    os.environ.get("AIDEVOPS_COMPLEXITY_WARN_THRESHOLD", str(_DEFAULT_THRESHOLD))
)

# Shell file extensions to inspect
SHELL_EXTENSIONS = {".sh", ".bash", ".zsh"}


def _is_shell_file(file_path: str) -> bool:
    """Return True if the file extension indicates a shell script."""
    if not file_path:
        return False
    _, ext = os.path.splitext(file_path)
    return ext.lower() in SHELL_EXTENSIONS


# Regex to detect bash function declaration lines (module-level, compiled once)
_FUNC_RE = re.compile(
    r"""
    ^\s*
    (?:
        function\s+(\w+)\s*(?:\(\s*\))?\s*\{   # function name() { or function name {
        |
        (\w+)\s*\(\s*\)\s*\{                    # name() {
    )
    """,
    re.VERBOSE,
)


def _find_close_brace(lines: list[str], start: int) -> int:
    """Return the index of the closing brace for the function starting at `start`.

    Uses a simple brace-depth counter (fast heuristic, sufficient for advisory).
    Returns -1 if no matching close is found before end-of-input.
    """
    depth = 0
    for j in range(start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth <= 0 and j > start:
            return j
    return -1


def _iter_function_blocks(text: str) -> Generator[tuple[str, int], None, None]:
    """Yield (function_name, line_count) for each bash function in text.

    Handles both declaration styles:
      - func_name() {
      - function func_name {
      - function func_name() {

    Line count includes the opening brace line and the closing brace line.
    Raises no exceptions — malformed bash is silently skipped.
    """
    lines = text.splitlines()
    n = len(lines)
    i = 0
    while i < n:
        m = _FUNC_RE.match(lines[i])
        if not m:
            i += 1
            continue
        func_name = m.group(1) or m.group(2)
        close = _find_close_brace(lines, i)
        if close >= 0:
            yield (func_name, close - i + 1)
            i = close + 1
        else:
            # No matching close — treat rest of file as body (edge case)
            remaining = n - i
            if remaining > 0:
                yield (func_name, remaining)
            break


def _build_advisory(warnings: list[tuple[str, int]]) -> str:
    """Format the advisory message for the user."""
    threshold = COMPLEXITY_WARN_THRESHOLD
    gate = 100  # function-complexity CI gate

    lines = [
        f"COMPLEXITY ADVISORY (complexity_advisory_pre_edit.py — t2864)",
        f"",
        f"Proposed edit contains {len(warnings)} function(s) exceeding {threshold} lines:",
        f"",
    ]
    for name, count in warnings:
        if count > gate:
            suffix = f"  ← EXCEEDS CI gate (>{gate})"
        else:
            suffix = f"  ← approaching CI gate ({threshold}/{gate})"
        lines.append(f"  • {name}: ~{count} lines{suffix}")
    lines += [
        f"",
        f"The function-complexity CI gate blocks PRs when any function exceeds {gate} lines.",
        f"Consider splitting before writing: orchestrator + sub-functions pattern.",
        f"",
        f"This advisory is informational only — the edit is NOT blocked.",
    ]
    return "\n".join(lines)


def main() -> None:
    """Read stdin hook input, check for large bash functions, emit advisory."""
    try:
        input_data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError, ValueError):
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    if tool_name not in ("Edit", "Write"):
        sys.exit(0)

    tool_input = input_data.get("tool_input") or {}

    # Get file path — Edit uses "filePath", Write uses "filePath" too
    file_path = tool_input.get("filePath", "")

    if not _is_shell_file(file_path):
        sys.exit(0)

    # Get the proposed content
    # Edit: newString contains the replacement text
    # Write: content contains the full new file content
    new_content = tool_input.get("newString") or tool_input.get("content") or ""

    if not new_content:
        sys.exit(0)

    # Find oversized functions
    warnings: list[tuple[str, int]] = []
    try:
        for func_name, line_count in _iter_function_blocks(new_content):
            if line_count > COMPLEXITY_WARN_THRESHOLD:
                warnings.append((func_name, line_count))
    except Exception:  # pylint: disable=broad-except
        # Parser errors must never block the edit
        sys.exit(0)

    if not warnings:
        sys.exit(0)

    advisory = _build_advisory(warnings)
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": advisory,
        }
    }
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
