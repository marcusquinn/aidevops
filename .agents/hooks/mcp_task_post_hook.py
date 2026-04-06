#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
PostToolUse hook for Claude Code: auto-record child subagent tokens (GH#17511).

Fires after every tool call. Filters for mcp_task (Task tool) completions,
extracts the child session's task_id, and calls gh-signature-helper.sh record-child.

Installed by: install-hooks-helper.sh
Location: ~/.aidevops/hooks/mcp_task_post_hook.py
Configured in: ~/.claude/settings.json (hooks.PostToolUse)

Exit behavior:
  - Exit 0 with no output = allow (post-hooks cannot block)
"""
import json
import os
import subprocess
import sys


def main():
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, EOFError):
        return

    tool_name = data.get("tool_name", "")
    if tool_name != "mcp_task":
        return

    tool_output = data.get("tool_output", {})
    if isinstance(tool_output, str):
        try:
            tool_output = json.loads(tool_output)
        except (json.JSONDecodeError, ValueError):
            pass

    task_id = ""
    if isinstance(tool_output, dict):
        task_id = tool_output.get("task_id", "") or tool_output.get("taskId", "")

    if not task_id:
        return

    helper = os.path.expanduser("~/.aidevops/agents/scripts/gh-signature-helper.sh")
    if os.path.isfile(helper):
        try:
            subprocess.Popen(
                [helper, "record-child", "--child", str(task_id)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass


if __name__ == "__main__":
    main()
