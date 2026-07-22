#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dynamic process-termination dispatch for the shared command policy."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from command_policy_config import _decision

TERMINATORS = {"kill", "killall", "pkill"}


def _is_process_termination_invocation(argv: list[str]) -> bool:
    if not argv:
        return False
    executable = os.path.basename(argv[0])
    if executable in TERMINATORS:
        return True
    return (
        executable in {"busybox", "toybox"}
        and len(argv) > 1
        and argv[1] in TERMINATORS
    )


def _process_termination_guard_path(
    policy: dict[str, Any], explicit: str, script_dir: Path | None = None
) -> Path:
    if explicit:
        return Path(explicit)
    helper = next(
        guard["helper"]
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "process_termination"
    )
    return (script_dir or Path(__file__).resolve().parent) / helper


def _evaluate_process_termination(
    invocations: list[list[str]],
    guard: Path,
    runtime_pid: int,
    runtime_process_identity: str,
    process_table_fixture: str,
) -> dict[str, Any]:
    termination_invocations = list(
        filter(_is_process_termination_invocation, invocations)
    )
    if not termination_invocations:
        return _decision(
            "allow",
            "process.no-termination-invocation",
            "No process-termination invocation detected",
        )
    if not guard.is_file():
        return _decision(
            "forbid",
            "process.guard-unavailable",
            "Required process-termination policy helper is unavailable",
        )
    for argv in termination_invocations:
        result = _run_process_termination_guard(
            argv,
            guard,
            runtime_pid,
            runtime_process_identity,
            process_table_fixture,
        )
        if result["decision"] != "allow":
            return result
    return _decision(
        "allow",
        "process.runtime-safe-target",
        "Process-termination targets are separate from the current runtime",
    )


def _guard_command(
    argv: list[str],
    guard: Path,
    runtime_pid: int,
    runtime_process_identity: str,
    process_table_fixture: str,
) -> list[str]:
    command = [
        sys.executable,
        str(guard),
        "check",
        "--argv-json",
        json.dumps(argv),
        "--runtime-pid",
        str(runtime_pid),
        "--runtime-process-identity",
        runtime_process_identity,
    ]
    if process_table_fixture:
        command.extend(["--process-table-fixture", process_table_fixture])
    return command


def _valid_guard_payload(payload: Any) -> bool:
    if not isinstance(payload, dict) or payload.get("schema_version") != 2:
        return False
    if payload.get("decision") not in {"allow", "forbid"}:
        return False
    return all(
        isinstance(payload.get(key), str) and bool(payload[key])
        for key in ("rule_id", "reason")
    )


def _run_process_termination_guard(
    argv: list[str],
    guard: Path,
    runtime_pid: int,
    runtime_process_identity: str,
    process_table_fixture: str,
) -> dict[str, Any]:
    command = _guard_command(
        argv,
        guard,
        runtime_pid,
        runtime_process_identity,
        process_table_fixture,
    )
    try:
        completed = subprocess.run(  # nosec B603 -- interpreter and policy-selected helper are fixed.
            command,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return _decision(
            "forbid",
            "process.guard-error",
            f"Process-termination policy failed closed: {exc}",
        )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = None
    if not _valid_guard_payload(payload):
        return _decision(
            "forbid",
            "process.guard-error",
            "Process-termination policy returned malformed output",
        )
    if completed.returncode != 0 and payload["decision"] == "allow":
        return _decision(
            "forbid",
            "process.guard-error",
            "Process-termination policy failed closed",
        )
    return payload
