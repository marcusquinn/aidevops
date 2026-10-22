#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded recovery diagnostics, without private paths or raw child output."""

import errno
import hashlib
from pathlib import Path
import re
import subprocess

DIAGNOSTIC_PREFIX = "archive-restore-diagnostic:"
DIAGNOSTIC_HINTS = {
    "no-space": "No space left on device",
    "reference-lock": "cannot lock ref",
    "file-exists": "File exists",
    "permission-denied": "Permission denied",
    "database-locked": "database is locked",
    "ownership-transaction": "Worktree ownership transaction unavailable",
    "invalid-reference": "invalid reference",
    "missing-object": "not a valid object",
}
GIT_OPERATIONS = {"fetch", "bundle", "worktree", "cat-file", "rev-parse", "update-ref"}
FAILURE_DIAGNOSTIC_FIELDS = (
    "failure_exit_status", "failure_child_exit_status", "failure_child_stderr_sha256",
    "failure_git_operation", "failure_hints",
)


def restore_diagnostic(error):
    """Summarize captured child errors without emitting paths, argv or raw stderr."""
    data = getattr(error, "stderr", None) or b""
    if isinstance(data, str):
        data = data.encode("utf-8", errors="replace")
    text = data.decode("utf-8", errors="replace")
    values = ["stderr-sha256:" + hashlib.sha256(data).hexdigest()]
    if isinstance(error, subprocess.CalledProcessError):
        values.append("exit-status:" + str(error.returncode))
        command = error.cmd
        if isinstance(command, (list, tuple)) and command and Path(str(command[0])).name == "git":
            operation = next((arg for arg in command[1:] if arg in GIT_OPERATIONS), None)
            if operation:
                values.append("git-operation:" + operation)
    values.extend("hint:" + hint for hint, phrase in DIAGNOSTIC_HINTS.items() if phrase in text)
    return "\n".join(DIAGNOSTIC_PREFIX + value for value in values)


def child_failure(error):
    diagnostic = error.stderr or ""
    if isinstance(diagnostic, bytes):
        diagnostic = diagnostic.decode(errors="replace")
    details = {"failure_exit_status": error.returncode}
    # Accept fixed tokens only: stderr and argv can contain private paths/data.
    hints = [hint for hint in DIAGNOSTIC_HINTS
             if DIAGNOSTIC_PREFIX + "hint:" + hint in diagnostic.splitlines()]
    if hints:
        details["failure_hints"] = hints
    patterns = {"failure_child_exit_status": r"exit-status:(-?[0-9]{1,9})",
                "failure_child_stderr_sha256": r"stderr-sha256:([0-9a-f]{64})",
                "failure_git_operation": r"git-operation:(" + "|".join(sorted(GIT_OPERATIONS)) + r")"}
    for key, pattern in patterns.items():
        match = re.search("^" + DIAGNOSTIC_PREFIX + pattern + "$", diagnostic, re.MULTILINE)
        if match:
            details[key] = int(match[1]) if key == "failure_child_exit_status" else match[1]
    code = "compaction:unknown-failure"
    if "No space left on device" in diagnostic or "no-space" in hints:
        code = "migration:no-space"
    elif "artifact integrity mismatch:" in diagnostic:
        code = "archive:artifact-integrity-mismatch"
    elif "unsupported untracked path type" in diagnostic:
        code = "archive:unsupported-untracked-path"
    return code, details


def framework_code(error):
    candidate = str(error).split(";", 1)[0]
    valid = candidate.startswith(("migration:", "retirement:", "restore-proof:", "git_admin:"))
    bounded = len(candidate) <= 128 and all(char.isalnum() or char in ":-_" for char in candidate)
    return candidate if valid and bounded else "compaction:unknown-failure"


def failure_details(error, stage):
    """Emit bounded codes from actual errno/helper diagnostics; unknowns block."""
    code = "compaction:unknown-failure"
    details = {}
    if isinstance(error, OSError) and error.errno == errno.ENOSPC:
        code = "migration:no-space"
    elif isinstance(error, BlockingIOError) and error.errno in (errno.EAGAIN, errno.EACCES):
        code = "migration:lock-busy"
    elif isinstance(error, subprocess.TimeoutExpired):
        code = "compaction:deadline"
    elif isinstance(error, ValueError):
        code = framework_code(error)
    elif isinstance(error, subprocess.CalledProcessError):
        code, details = child_failure(error)
    return {"failure_code": code, "failure_stage": getattr(error, "recovery_stage", stage), **details}
