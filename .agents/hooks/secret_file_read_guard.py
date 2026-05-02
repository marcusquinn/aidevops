#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code PreToolUse guard: block secret/private-key file reads."""

from __future__ import annotations

import json
import os
import re
import sys

SECRET_BASENAME_RE = re.compile(
    r"^(id_(rsa|dsa|ecdsa|ed25519)|\.env(\..*)?|credentials(\.sh|\.json|\.ya?ml)?|service-account(\.json)?|kubeconfig|config\.json|op-vault-export.*|.*password.*|.*passwd.*|.*secret.*)$",
    re.IGNORECASE,
)
SECRET_EXTENSION_RE = re.compile(r"\.(pem|key|p12|pfx|kdbx|age|asc|gpg)$", re.IGNORECASE)
PUBLIC_KEY_RE = re.compile(r"\.pub$", re.IGNORECASE)
SECRET_PATH_RE = re.compile(
    r"(^|[/\\])(\.ssh|\.gnupg|\.aws|\.azure|\.config[/\\]gcloud|\.kube|1password|op-vault|password-store)([/\\]|$)",
    re.IGNORECASE,
)
READ_TOOLS = {"Read", "read", "Glob", "glob", "NotebookRead", "notebook_read"}


def extract_path(tool_input: dict) -> str:
    """Extract a path-like argument from a Claude Code read tool payload."""
    return str(
        tool_input.get("filePath")
        or tool_input.get("file_path")
        or tool_input.get("path")
        or tool_input.get("pattern")
        or ""
    )


def secret_read_block_reason(path: str) -> str:
    """Return a deny reason for high-risk secret paths, or empty string."""
    if not path:
        return ""
    normalized = os.path.normpath(path)
    base = os.path.basename(normalized)
    if PUBLIC_KEY_RE.search(base):
        return ""
    if SECRET_BASENAME_RE.search(base):
        return "secret-bearing basename"
    if SECRET_EXTENSION_RE.search(base):
        return "secret-bearing file extension"
    if SECRET_PATH_RE.search(normalized):
        return "credential-store path"
    return ""


def deny(path: str, reason: str) -> dict:
    """Build a Claude Code PreToolUse deny response."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "BLOCKED by secret_file_read_guard.py (aidevops)\n\n"
                f"Reason: {reason}\n\n"
                f"Path: {path}\n\n"
                "Secret/private-key files must not be read into model context. "
                "Use a synthetic fixture or ask the user to inspect the file locally. "
                "Public key files ending .pub are allowed."
            ),
        }
    }


def main() -> None:
    """Read Claude hook payload from stdin and deny unsafe file reads."""
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return

    tool_name = data.get("tool_name", "")
    if tool_name not in READ_TOOLS:
        return

    tool_input = data.get("tool_input") or {}
    path = extract_path(tool_input)
    reason = secret_read_block_reason(path)
    if reason:
        print(json.dumps(deny(path, reason)))


if __name__ == "__main__":
    main()
