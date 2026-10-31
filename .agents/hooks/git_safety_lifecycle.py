# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Runtime-parent admission adapter; policy helpers own the registry protocol."""

import os
import subprocess
import sys


def check_session_owner(resolve_helper, run_helper, paths, session_id, command=""):
    """Register the runtime parent, not this short-lived hook process."""
    if sys.platform not in {"linux", "darwin"}:
        return None
    helper = resolve_helper(
        "AIDEVOPS_LIFECYCLE_SESSION_HELPER", "worker-lifecycle-session-helper.py",
    )
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
            if returncode == 0 and payload.get("status") in {
                "admitted", "excluded-unregistered", "not-applicable",
            }:
                return None
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            pass
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: lifecycle owner admission unavailable",
    }}
