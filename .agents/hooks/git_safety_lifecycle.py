# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Runtime-parent admission adapter; policy helpers own the registry protocol."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys


def diagnostic_advisory(payload, session_id):
    """Return advisory-only output once across short-lived hooks in a session."""
    if not payload.get("diagnostic") or not session_id:
        return None
    marker_dir = (Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
                  / "lifecycle-advisory")
    marker = marker_dir / hashlib.sha256(session_id.encode()).hexdigest()
    try:
        marker_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with marker.open("x"):
            pass
    except OSError:
        # Existing marker or unwritable advisory state never changes admission.
        return None
    message = ("[worker-lifecycle] coverage-gap: schema-upgrade-required; "
               "lifecycle coverage is observe-only until the store is upgraded. "
               "No owner admitted or cleanup authorized. This operation is not blocked.")
    return {"systemMessage": message, "hookSpecificOutput": {
        "hookEventName": "PreToolUse", "additionalContext": message,
    }}


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
            # coverage-gap: valid schema-1 store, observe-only (GH#36349).
            if returncode == 0 and payload.get("status") in {
                "admitted", "coverage-gap", "excluded-unregistered", "not-applicable",
            }:
                return diagnostic_advisory(payload, session_id)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            pass
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": "BLOCKED: lifecycle owner admission unavailable",
    }}
