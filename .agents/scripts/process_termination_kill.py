#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Explicit PID and process-group kill command evaluation."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from process_termination_common import GuardError, _allow, _forbid, _signal_value

INSPECTION_OPTIONS = {"-l", "--list", "-L", "--table"}
SIGNAL_OPTIONS = {"-s", "--signal"}
QUEUE_OPTIONS = {"-q", "--queue"}


@dataclass
class KillSpec:
    """Parsed kill command state."""

    signal_value: str = "TERM"
    signal_seen: bool = False
    targets: list[str] = field(default_factory=list)
    inspection: bool = False


def _consume_signal_option(argv: list[str], index: int, spec: KillSpec) -> int | None:
    token = argv[index]
    if token in SIGNAL_OPTIONS:
        if index + 1 >= len(argv):
            raise GuardError("process-termination signal is incomplete")
        spec.signal_value = argv[index + 1]
        spec.signal_seen = True
        return index + 2
    if token.startswith("--signal="):
        spec.signal_value = token.split("=", 1)[1]
        spec.signal_seen = True
        return index + 1
    candidate = _signal_value(token) if token.startswith("-") else None
    if candidate is not None and not spec.signal_seen:
        spec.signal_value = candidate
        spec.signal_seen = True
        return index + 1
    return None


def _consume_queue_option(argv: list[str], index: int) -> int | None:
    if argv[index] not in QUEUE_OPTIONS:
        return None
    if index + 1 >= len(argv):
        raise GuardError("process-termination queue option is incomplete")
    return index + 2


def _parse_kill(argv: list[str]) -> KillSpec:
    spec = KillSpec()
    index = 1
    while index < len(argv):
        token = argv[index]
        if spec.targets:
            spec.targets.extend(argv[index:])
            break
        if token == "--":
            spec.targets.extend(argv[index + 1 :])
            break
        if token in INSPECTION_OPTIONS:
            spec.inspection = True
            break
        next_index = _consume_signal_option(argv, index, spec)
        if next_index is None:
            next_index = _consume_queue_option(argv, index)
        if next_index is None:
            spec.targets.append(token)
            index += 1
        else:
            index = next_index
    return spec


def _is_kill_inspection(argv: list[str]) -> bool:
    spec = _parse_kill(argv)
    return (
        spec.inspection
        or _signal_value(spec.signal_value) == "0"
        or not spec.targets
    )


def _evaluate_kill(
    argv: list[str],
    runtime_pid: int,
    protected_pids: set[int],
    protected_pgids: set[int],
) -> dict[str, Any]:
    spec = _parse_kill(argv)
    if _is_kill_inspection(argv):
        return _allow("Process signal inspection does not terminate the runtime")
    for target in spec.targets:
        if not re.fullmatch(r"[+-]?[0-9]+", target):
            raise GuardError("process-termination target is not an explicit PID or PGID")
        numeric = int(target, 10)
        if numeric in {0, -1}:
            return _forbid(
                "process.runtime-self-preservation",
                "Refusing a broad signal that can reach the current runtime process group",
            )
        if numeric > 0 and numeric in protected_pids:
            relation = "host" if numeric == runtime_pid else "ancestor"
            return _forbid(
                "process.runtime-self-preservation",
                f"Refusing to terminate the current runtime {relation}",
            )
        if numeric < -1 and abs(numeric) in protected_pgids:
            return _forbid(
                "process.runtime-self-preservation",
                "Refusing to terminate a process group containing the current runtime lineage",
            )
    return _allow("Explicit PID and PGID targets are separate from the runtime lineage")
