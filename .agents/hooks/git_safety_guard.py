#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code adapter for shared command and direct-write safety.

Shell-command decisions are delegated to command-policy-helper.py. Direct file
mutations are delegated to canonical-write-policy-helper.py so every canonical
checkout is read-only regardless of branch name or target path.

This hook runs before Bash/Edit/Write tool calls execute. It is registered under
both the Bash and direct-file-tool PreToolUse matchers.

Installed by: aidevops setup (setup.sh) or install-hooks-helper.sh
Location: ~/.aidevops/hooks/git_safety_guard.py
Configured in: ~/.claude/settings.json (hooks.PreToolUse)

Based on: github.com/Dicklesworthstone/misc_coding_agent_tips_and_scripts
Adapted for aidevops framework (https://aidevops.sh)

Exit behavior:
  - Exit 0 with JSON {"hookSpecificOutput": {"permissionDecision": "deny", ...}} = block
  - Exit 0 with no output = allow

"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

GIT_BINARY = os.environ.get("AIDEVOPS_REAL_GIT", "")
if not GIT_BINARY:
    GIT_BINARY = (
        "/usr/bin/git"
        if os.path.isfile("/usr/bin/git")
        else (shutil.which("git") or "git")
    )

DIRECT_FILE_TOOL_NAMES = {"edit", "write", "apply_patch", "applypatch"}
WORKER_ENV_KEYS = (
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "Claude_HEADLESS",
    "HEADLESS",
    "GITHUB_ACTIONS",
)


def _is_worker_context() -> bool:
    """Return True when this per-tool hook is running in a worker process."""
    if os.environ.get("AIDEVOPS_WORKER_ID", ""):
        return True
    return any(
        os.environ.get(key, "").lower() in {"1", "true", "yes"}
        for key in WORKER_ENV_KEYS
    )


def _normalise_tool_name(tool_name: str) -> str:
    """Return the leaf tool name for built-in and namespaced variants."""
    normalised = tool_name.replace("::", ".").replace("/", ".")
    return normalised.rsplit(".", 1)[-1].replace("-", "_").lower()


def _is_direct_file_tool(tool_name: str) -> bool:
    """Return whether a tool can mutate a file without a Bash command."""
    return _normalise_tool_name(tool_name) in DIRECT_FILE_TOOL_NAMES


def _canonical_write_policy_helper() -> str:
    """Resolve the shared canonical-write policy helper."""
    candidates = [
        os.environ.get("AIDEVOPS_CANONICAL_WRITE_POLICY_HELPER", ""),
        str(
            Path(__file__).resolve().parent.parent
            / "scripts"
            / "canonical-write-policy-helper.py"
        ),
        str(
            Path.home()
            / ".aidevops"
            / "agents"
            / "scripts"
            / "canonical-write-policy-helper.py"
        ),
    ]
    return next((path for path in candidates if path and os.path.isfile(path)), "")


def _direct_write_deny(reason: str) -> dict:
    """Build the Claude Code deny payload for a direct file mutation."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "BLOCKED by canonical write policy\n\n"
                f"Reason: {reason}\n\n"
                "ACTION_REQUIRED=create_or_use_linked_worktree"
            ),
        }
    }


def _check_canonical_write(file_path: str) -> "dict | None":
    """Delegate a direct file mutation to the shared structural policy."""
    helper = _canonical_write_policy_helper()
    if not helper:
        return _direct_write_deny("required canonical-write policy is unavailable")
    try:
        result = subprocess.run(
            [
                sys.executable,
                helper,
                "check-write",
                "--cwd",
                os.getcwd(),
                "--path",
                file_path,
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        payload = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return _direct_write_deny(f"canonical-write policy failed closed: {exc}")
    if result.returncode == 0 and payload.get("decision") == "allow":
        return None
    return _direct_write_deny(
        payload.get("reason", "canonical-write policy returned an invalid response")
    )


def _check_command_policy(command: str) -> "dict | None":
    """Return a Claude deny payload unless the shared safety floor allows."""
    candidates = [
        os.environ.get("AIDEVOPS_COMMAND_POLICY_HELPER", ""),
        str(Path(__file__).resolve().parent.parent / "scripts" / "command-policy-helper.py"),
        str(Path.home() / ".aidevops" / "agents" / "scripts" / "command-policy-helper.py"),
    ]
    helper = next((path for path in candidates if path and os.path.isfile(path)), "")
    decision = "forbid"
    rule_id = "policy.helper-unavailable"
    reason = "required command safety policy helper is unavailable"
    if helper:
        helper_args = [
            sys.executable,
            helper,
            "check-command",
            "--cwd",
            os.getcwd(),
            "--command",
            command,
        ]
        if _is_worker_context():
            helper_args.extend(
                ["--worker", "--worker-id", os.environ.get("AIDEVOPS_WORKER_ID", "claude-worker")]
            )
        try:
            result = subprocess.run(
                helper_args,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            rule_id = "policy.helper-error"
            reason = f"command safety policy failed closed: {exc}"
        else:
            try:
                payload = json.loads(result.stdout)
            except (json.JSONDecodeError, TypeError):
                payload = {}
            decision = payload.get("decision", "forbid")
            rule_id = payload.get("rule_id", "policy.invalid-response")
            reason = payload.get(
                "reason", "command safety policy returned an invalid response"
            )
            if result.returncode == 0 and decision == "allow":
                return None
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED by shared command policy ({decision}, {rule_id})\n\n"
                f"Reason: {reason}"
            ),
        }
    }


def main():
    """Delegate Bash policy and enforce direct-file worktree isolation."""
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input") or {}

    if _is_direct_file_tool(tool_name):
        file_path = (
            tool_input.get("filePath", "")
            or tool_input.get("file_path", "")
            or tool_input.get("path", "")
        )
        deny = _check_canonical_write(file_path)
        if deny:
            print(json.dumps(deny))
        sys.exit(0)

    command = tool_input.get("command", "")
    if tool_name != "Bash" or not isinstance(command, str) or not command:
        sys.exit(0)
    deny = _check_command_policy(command)
    if deny:
        print(json.dumps(deny))
    sys.exit(0)


if __name__ == "__main__":
    main()
