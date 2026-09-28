#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code PreToolUse guard: block secret/private-key file reads."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess  # nosec B404 - fixed git argv, no shell
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
# GH#32526: loose name hints (secret/password/passwd) are routine in framework
# source and docs. Tracked code/doc files carrying only these hints are
# readable; strong credential names and every other extension stay blocked.
LOOSE_SECRET_BASENAME_RE = re.compile(r"(secret|password|passwd)", re.IGNORECASE)
STRONG_SECRET_HINT_RE = re.compile(
    r"(^\.env|^id_(rsa|dsa|ecdsa|ed25519)|credential|service-account|kubeconfig|op-vault)",
    re.IGNORECASE,
)
TRACKED_SOURCE_EXTENSION_RE = re.compile(r"\.(sh|mjs|js|ts|py|md)$", re.IGNORECASE)
GIT_ENV_OVERRIDES = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_CEILING_DIRECTORIES",
)


def _git_environment() -> dict:
    env = {key: value for key, value in os.environ.items() if key not in GIT_ENV_OVERRIDES}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def is_tracked_source_with_loose_secret_name(path: str) -> bool:
    """True for a regular, single-link, git-tracked code/doc file whose
    basename carries only loose secret hints.

    #aidevops:trust-boundary - tracked status comes from git in the file's own
    repository, never from path text; symlinks and hard links are refused.
    """
    if not path:
        return False
    absolute = os.path.abspath(os.path.normpath(path))
    base = os.path.basename(absolute)
    if not LOOSE_SECRET_BASENAME_RE.search(base) or STRONG_SECRET_HINT_RE.search(base):
        return False
    if not TRACKED_SOURCE_EXTENSION_RE.search(base) or SECRET_PATH_RE.search(absolute):
        return False
    try:
        info = os.lstat(absolute)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            return False
        directory = os.path.realpath(os.path.dirname(absolute))
        if SECRET_PATH_RE.search(directory):
            return False
        result = subprocess.run(  # nosec B603 - fixed git argv, no shell
            ["git", "-c", "core.fsmonitor=false", "-C", directory, "ls-files", "--error-unmatch", "--", base],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            env=_git_environment(),
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


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
    if SECRET_BASENAME_RE.search(base) and not is_tracked_source_with_loose_secret_name(normalized):
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
