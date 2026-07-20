#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code adapter for shared command and direct-write safety.

Shell-command decisions are delegated to command-policy-helper.py. Direct file
mutations are delegated to canonical-write-policy-helper.py so canonical
checkout targets stay read-only while explicit linked-worktree targets work.

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

DIRECT_FILE_TOOL_NAMES = {
    "edit",
    "edit_file",
    "write",
    "write_file",
    "apply_patch",
    "applypatch",
}
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


def _resolve_policy_helper(environment_key: str, filename: str) -> str:
    """Resolve a repository or deployed policy helper."""
    candidates = [
        os.environ.get(environment_key, ""),
        str(Path(__file__).resolve().parent.parent / "scripts" / filename),
        str(Path.home() / ".aidevops" / "agents" / "scripts" / filename),
    ]
    return next((path for path in candidates if path and os.path.isfile(path)), "")


def _run_policy_helper(helper: str, arguments: list, input_text=None):
    """Execute a validated Python policy helper and require an object payload."""
    # nosec B603 -- fixed interpreter and policy argv, no shell
    result = subprocess.run(  # nosec B603
        [sys.executable, helper, *arguments],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    payload = json.loads(result.stdout)
    if not isinstance(payload, dict):
        raise TypeError("policy helper returned a non-object payload")
    return result.returncode, payload


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


def _check_canonical_write(
    file_path: str, patch_text: "str | None" = None
) -> "dict | None":
    """Delegate a direct file mutation to the shared structural policy."""
    helper = _resolve_policy_helper(
        "AIDEVOPS_CANONICAL_WRITE_POLICY_HELPER",
        "canonical-write-policy-helper.py",
    )
    if not helper:
        return _direct_write_deny("required canonical-write policy is unavailable")
    if patch_text is not None and not isinstance(patch_text, str):
        return _direct_write_deny("apply-patch payload is not text")
    try:
        helper_args = [
            "check-patch" if patch_text is not None else "check-write",
            "--cwd",
            os.getcwd(),
        ]
        if patch_text is None:
            helper_args.extend(["--path", file_path])
        returncode, payload = _run_policy_helper(helper, helper_args, patch_text)
    except (
        OSError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
        TypeError,
    ) as exc:
        return _direct_write_deny(f"canonical-write policy failed closed: {exc}")
    if returncode == 0 and payload.get("decision") == "allow":
        return None
    return _direct_write_deny(
        payload.get("reason", "canonical-write policy returned an invalid response")
    )


def _check_command_policy(command: str) -> "dict | None":
    """Return a Claude deny payload unless the shared safety floor allows."""
    helper = _resolve_policy_helper(
        "AIDEVOPS_COMMAND_POLICY_HELPER", "command-policy-helper.py"
    )
    decision = "forbid"
    rule_id = "policy.helper-unavailable"
    reason = "required command safety policy helper is unavailable"
    if helper:
        helper_args = [
            "check-command",
            "--cwd",
            os.getcwd(),
            "--command",
            command,
        ]
        if _is_worker_context():
            helper_args.extend(
                [
                    "--worker",
                    "--worker-id",
                    os.environ.get("AIDEVOPS_WORKER_ID", "claude-worker"),
                ]
            )
        try:
            returncode, payload = _run_policy_helper(helper, helper_args)
        except (
            OSError,
            subprocess.SubprocessError,
            json.JSONDecodeError,
            TypeError,
        ) as exc:
            rule_id = "policy.helper-error"
            reason = f"command safety policy failed closed: {exc}"
        else:
            decision = payload.get("decision", "forbid")
            rule_id = payload.get("rule_id", "policy.invalid-response")
            reason = payload.get(
                "reason", "command safety policy returned an invalid response"
            )
            if returncode == 0 and decision == "allow":
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
        patch_text = None
        if _normalise_tool_name(tool_name) in {"apply_patch", "applypatch"}:
            patch_text = tool_input.get("patchText", "") or tool_input.get(
                "patch_text", ""
            )
        deny = _check_canonical_write(file_path, patch_text)
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
