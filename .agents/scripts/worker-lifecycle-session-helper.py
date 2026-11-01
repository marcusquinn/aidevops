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

from canonical_git_invocation import split_invocation
from canonical_git_policy import _git_repo_identity
from canonical_write_policy_paths import classify_location
from command_policy_parser import _shell_invocations
from native_git import real_git

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "worker-lifecycle"))

from worker_lifecycle.enrollment import _git_directory
from worker_lifecycle.launch import initialize_or_open, require_unregistered
from worker_lifecycle.process import ObservationUnavailable
from worker_lifecycle.runtime import adapter_for, require_ready
from worker_lifecycle.session import admit_session

SCRIPTS = Path(__file__).resolve().parent


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


def command_targets(cwd, command, argv_json):
    """Resolve literal command declarations, never infer process cwd ownership."""
    invocations = _shell_invocations(command) if command else []
    if argv_json:
        argv = json.loads(argv_json)
        if not isinstance(argv, list) or not all(isinstance(v, str) for v in argv):
            raise ValueError("invalid-command-argv")
        invocations.append(argv)
    targets = {cwd}
    for argv in invocations:
        if not argv or Path(argv[0]).name != "git":
            continue
        prefix, effective, verb, _ = split_invocation(argv[1:], str(cwd))
        if not prefix or not verb:
            continue
        common, directory, top = _git_repo_identity(real_git(), effective, prefix)
        if not all((common, directory, top)) or not Path(top).is_absolute():
            raise ValueError("git-target-unavailable")
        target = Path(top)
        if (Path(common).resolve() != Path(directory).resolve()
                and _git_directory(target) != Path(directory).resolve()):
            raise ValueError("inconsistent-git-target")
        targets.add(target)
    return targets


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
    require_ready(adapter_for(str(uuid4())))
    store = initialize_or_open(state)
    for root in sorted(roots):
        admit_session(store, root, pid, session_id)
    return "admitted"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--path", type=Path, action="append", default=[])
    parser.add_argument("--runtime-pid", type=int, required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--command", default="")
    parser.add_argument("--argv-json", default="")
    args = parser.parse_args()
    try:
        targets = args.path
        if args.command or args.argv_json:
            targets = [
                *targets, *command_targets(args.cwd, args.command, args.argv_json),
            ]
        status = admit_targets(args.cwd, targets, args.runtime_pid, args.session_id)
    except (ValueError, OSError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError, ObservationUnavailable) as error:
        print(json.dumps({"status": "unavailable", "reason": type(error).__name__}))
        return 75
    print(json.dumps({"status": status, "cleanup_authorized": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
