# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Runtime-parent admission adapter; policy helpers own the registry protocol."""

import os
import re
import subprocess
import sys


def check_session_owner(resolve_helper, run_helper, paths, session_id, command=""):
    """Register the runtime parent, not this short-lived hook process."""
    if sys.platform not in {"linux", "darwin"}:
        return None
    helper = resolve_helper(
        "AIDEVOPS_LIFECYCLE_SESSION_HELPER", "worker-lifecycle-session-helper.py",
    )
    reason = "helper-unavailable"
    if helper:
        # #aidevops:trust-boundary — the installed hook execs directly under
        # the runtime. A command-authored PID or session override is not used.
        arguments = ["--cwd", os.getcwd(), "--runtime-pid", str(os.getppid()),
                     "--session-id", session_id]
        for path in paths:
            arguments.extend(["--path", path])
        if command:
            arguments.extend(["--command", command])
        try:
            returncode, payload = run_helper(helper, arguments, isolate_python=True)
            # coverage-gap: valid schema-1 store, observe-only (GH#36349).
            if returncode == 0 and payload.get("status") in {
                "admitted", "coverage-gap", "excluded-unregistered", "not-applicable",
            }:
                return None
            reason = _safe_reason(payload.get("reason")) or f"helper-exit-{returncode}"
        except (OSError, subprocess.SubprocessError, ValueError, TypeError, AttributeError):
            reason = "helper-failed"
    # The helper's reason is a fixed protocol token; never host paths (GH#36430).
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": f"BLOCKED: lifecycle owner admission unavailable ({reason})",
    }}


def _safe_reason(value):
    """Accept only short protocol tokens, never free-form helper output."""
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,63}", value):
        return value
    return ""
