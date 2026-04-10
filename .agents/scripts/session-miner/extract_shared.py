#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared helpers for session-miner extraction scripts."""

from pathlib import Path
from typing import Any


def sanitize_path(path: str) -> str:
    """Strip user-specific path components, keeping project-relevant parts."""
    if not path:
        return ""

    parts = Path(path).parts
    for index, part in enumerate(parts):
        if part == "Git" and index + 1 < len(parts):
            return "/".join(parts[index + 1:])

    return "/".join(parts[-2:]) if len(parts) >= 2 else path


def _summarize_file_tool(tool: str, tool_input: dict) -> str:
    """Summarize a file-based tool call (edit/read/write)."""
    file_path = tool_input.get("filePath", "")
    return f"{tool} {Path(file_path).name}" if file_path else tool


def _summarize_bash_tool(_tool: str, tool_input: dict) -> str:
    """Summarize a bash tool call."""
    command = tool_input.get("command", "")
    return f"bash: {command[:80].replace(chr(10), ' ')}" if command else "bash"


_TOOL_SUMMARIZERS: dict[str, Any] = {
    "edit": _summarize_file_tool,
    "read": _summarize_file_tool,
    "write": _summarize_file_tool,
    "bash": _summarize_bash_tool,
    "glob": lambda _tool, tool_input: f"glob: {tool_input.get('pattern', '')}",
    "grep": lambda _tool, tool_input: f"grep: {tool_input.get('pattern', '')}",
    "webfetch": lambda _tool, tool_input: f"fetch: {tool_input.get('url', '')[:80]}",
}


def summarize_tool_input(tool: str, tool_input: Any) -> str:
    """Create a brief summary of what a tool call was trying to do."""
    if not isinstance(tool_input, dict):
        return ""

    summarizer = _TOOL_SUMMARIZERS.get(tool)
    if summarizer is None:
        return tool

    return summarizer(tool, tool_input)
