#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code adapter for shared command and direct-write safety.

Shell-command decisions are delegated to command-policy-helper.py. Direct file
mutations are delegated to canonical-write-policy-helper.py so every canonical
checkout is read-only regardless of branch name or target path.

This hook runs before Bash/Edit/Write tool calls execute. It is registered under
both the Bash and direct-file-tool PreToolUse matchers, and under the
WebFetch/MCP matcher so URL-bearing tools never open redirect links (GH#35655).

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
import subprocess
import sys
from pathlib import Path

# Git discovery is owned by native_git.py inside the shared policy helpers,
# not by this adapter. Keeping an unused binary fallback here hid divergence.

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


def _process_identity(pid: int) -> str:
    """Return the portable process-generation token used by lifecycle locks."""
    ps_binary = "/bin/ps" if os.path.isfile("/bin/ps") else "ps"
    try:
        result = subprocess.run(  # nosec B603 -- fixed system process viewer
            [ps_binary, "-p", str(pid), "-o", "lstart="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return " ".join(result.stdout.split())


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
        # #aidevops:trust-boundary — the hook's parent is the current Claude
        # runtime launcher; command-local environment text cannot alter it.
        runtime_pid = os.getppid()
        helper_args.extend(
            [
                "--runtime-pid",
                str(runtime_pid),
                "--runtime-process-identity",
                _process_identity(runtime_pid),
            ]
        )
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


URL_SHAPED_MARKERS = ("://", "www.", "hxxp", "[.]", "%2e", "\uff0e", "\u3002")
REDIRECT_EXEMPT_TOOLS = {"bash", "read", "grep", "glob", "task", "todowrite", "notebookread"}


def _collect_url_strings(value, out: list, depth: int = 0) -> list:
    """Collect URL-shaped strings from nested tool arguments."""
    if len(out) >= 200 or depth > 6 or value is None:
        return out
    if isinstance(value, str):
        lowered = value.lower()
        if any(marker in lowered for marker in URL_SHAPED_MARKERS):
            out.append(value)
    elif isinstance(value, list):
        for item in value:
            _collect_url_strings(item, out, depth + 1)
    elif isinstance(value, dict):
        for item in value.values():
            _collect_url_strings(item, out, depth + 1)
    return out


def _check_redirect_links(tool_name: str, tool_input) -> "dict | None":
    """Deny URL-bearing tools that would resolve a redirect link (GH#35655).

    Lexical only via redirect_link_policy.py; never touches the network.
    Bash is covered by the shared command policy; file tools are exempt.
    """
    leaf = _normalise_tool_name(tool_name)
    if leaf in REDIRECT_EXEMPT_TOOLS or _is_direct_file_tool(tool_name):
        return None
    strings = _collect_url_strings(tool_input, [])
    if not strings:
        return None
    scanner = _resolve_policy_helper(
        "AIDEVOPS_REDIRECT_LINK_POLICY", "redirect_link_policy.py"
    )
    reason = "redirect-link policy scanner is unavailable"
    if scanner:
        try:
            # nosec B603 -- fixed interpreter and scanner path, no shell
            result = subprocess.run(  # nosec B603
                [sys.executable, scanner, "scan"],
                input="\n".join(strings),
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            reason = f"redirect-link policy scanner failed: {exc}"
        else:
            if result.returncode == 0:
                return None
            if result.returncode == 1:
                try:
                    hosts = sorted(
                        {item["host"] for item in json.loads(result.stdout)["redirect_links"]}
                    )
                except (json.JSONDecodeError, KeyError, TypeError):
                    hosts = ["redirect host"]
                reason = (
                    f"redirect/shortener link ({', '.join(hosts)}) must never be "
                    "resolved, fetched or opened in any session, including remote "
                    "sandboxes. Treat the source content as spam (GH#35655)."
                )
            else:
                reason = "redirect-link policy scanner returned an error"
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"BLOCKED by redirect-link policy\n\nReason: {reason}",
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

    redirect_deny = _check_redirect_links(tool_name, tool_input)
    if redirect_deny:
        print(json.dumps(redirect_deny))
        sys.exit(0)

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
