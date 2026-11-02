#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Admit runtime-identified owners of explicit tool targets; never scan processes."""

import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from uuid import uuid4

from canonical_write_policy_paths import classify_location
from worker_lifecycle_command_targets import command_targets

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "worker-lifecycle"))

from worker_lifecycle.enrollment import GenerationEnrollment, _git_directory
from worker_lifecycle.launch import initialize_or_open, require_unregistered
from worker_lifecycle.process import ObservationUnavailable
from worker_lifecycle.runtime import adapter_for, require_ready
from worker_lifecycle.session import admit_session

SCRIPTS = Path(__file__).resolve().parent
# Fixed protocol tokens only; never host paths, command text or SQL errors.
SAFE_REASONS = {
    "explicit-schema-upgrade-required",
    "schema-one-with-admission-state",
    "schema-one-with-generation-marker",
    "runtime-owner-unresolved",
    "git-target-unavailable",
    "inconsistent-git-target",
    "target-classification-unavailable",
    "explicit-absolute-context-required",
    "invalid-command-argv",
    "invalid-session-identity",
    "lifecycle-state-unavailable",
    "state-parent-must-be-canonical",
    "session-owner-already-ended",
    "generation-changed-during-session-admission",
}


def runtime_pid(value):
    """Return a positive runtime PID, or None when the runtime proved none."""
    text = (value or "").strip()
    if text.isdigit() and int(text) > 0:
        return int(text)
    if text:
        raise ValueError("runtime-owner-unresolved")
    return None


def state_directory():
    result = subprocess.run(  # nosec B603 B607 # fixed resolver, path passed as argv
        ["bash", "-c", 'source "$1" && worker_lifecycle_state_dir',
         "lifecycle-state", str(SCRIPTS / "worker-lifecycle-state.sh")],
        check=True, capture_output=True, text=True, timeout=10,
    )
    value = result.stdout.rstrip("\n")
    if not value:
        raise ValueError("lifecycle-state-unavailable")
    return Path(value)


def admit_targets(cwd, targets, pid, session_id):
    """The runtime declares targets; their Git roots identify resources, not owners."""
    if not cwd.is_absolute():
        raise ValueError("explicit-absolute-context-required")
    roots = set()
    for target in targets or [cwd]:
        location = classify_location(str(cwd / target))
        if location.classification == "unknown":
            raise ValueError("target-classification-unavailable")
        if location.classification == "linked":
            roots.add(Path(location.repo_root))
    if not roots:
        return "not-applicable"
    state = state_directory()
    excluded = any(os.environ.get(name) == "1" for name in (
        "AIDEVOPS_PRIVATE_WORKLOAD", "AIDEVOPS_LIFECYCLE_DISABLED",
    ))
    if excluded:
        for root in sorted(roots):
            require_unregistered(state, root)
        return "excluded-unregistered"
    store = initialize_or_open(state)
    enrollment = GenerationEnrollment(store)
    # Validate every target before accepting observation; no native owner is
    # required or admitted for this supported schema-1 compatibility path.
    gaps = [enrollment.has_schema_one_gap(root) for root in sorted(roots)]
    if all(gaps):
        return "coverage-gap"
    # #aidevops:trust-boundary — only linked worktrees need a runtime owner;
    # an unproven runtime is refused here, never replaced by a tool argument.
    if pid is None:
        raise ValueError("runtime-owner-unresolved")
    require_ready(adapter_for(str(uuid4())))
    for root in sorted(roots):
        admit_session(store, root, pid, session_id)
    return "admitted"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--path", type=Path, action="append", default=[])
    # An empty PID means the runtime proved no owner. Non-linked targets do not
    # need one; admit_targets refuses only linked targets without it (GH#36430).
    parser.add_argument("--runtime-pid", default="")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--command", default="")
    parser.add_argument("--argv-json", default="")
    args = parser.parse_args()
    try:
        targets = args.path
        if args.command or args.argv_json:
            targets = [
                *targets, *command_targets(
                    args.cwd, args.command, args.argv_json, _git_directory,
                ),
            ]
        status = admit_targets(
            args.cwd, targets, runtime_pid(args.runtime_pid), args.session_id,
        )
    except (ValueError, OSError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError, ObservationUnavailable) as error:
        # Expose safe protocol reasons, never host paths or SQL exception text.
        reason = str(error) if str(error) in SAFE_REASONS else type(error).__name__
        print(json.dumps({"status": "unavailable", "reason": reason}))
        return 75
    result = {"status": status, "cleanup_authorized": False}
    if status == "coverage-gap":
        result["reason"] = "schema-upgrade-required"
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
