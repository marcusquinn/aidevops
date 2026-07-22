#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Process-name killall command evaluation."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

from process_termination_common import (
    GuardError,
    ProcessRecord,
    _allow,
    _forbid,
    _safe_pattern_matches,
    _signal_value,
)

PASSIVE_FLAGS = {
    "-i",
    "-q",
    "-v",
    "-w",
    "--interactive",
    "--quiet",
    "--verbose",
    "--wait",
}


@dataclass
class KillallSpec:
    """Parsed killall command state."""

    signal_value: str = "TERM"
    regex_mode: bool = False
    ignore_case: bool = False
    inspection: bool = False
    names: list[str] = field(default_factory=list)


def _consume_killall_option(
    argv: list[str], index: int, spec: KillallSpec
) -> int | None:
    token = argv[index]
    next_index = None
    if token in {"-l", "--list"}:
        spec.inspection = True
        next_index = len(argv)
    elif (candidate := _signal_value(token) if token.startswith("-") else None) is not None:
        spec.signal_value = candidate
        next_index = index + 1
    elif token in {"-s", "--signal"}:
        if index + 1 >= len(argv):
            raise GuardError("killall signal is incomplete")
        spec.signal_value = argv[index + 1]
        next_index = index + 2
    elif token.startswith("--signal="):
        spec.signal_value = token.split("=", 1)[1]
        next_index = index + 1
    elif token in {"-r", "--regexp"}:
        spec.regex_mode = True
        next_index = index + 1
    elif token in {"-I", "--ignore-case"}:
        spec.ignore_case = True
        next_index = index + 1
    elif token in PASSIVE_FLAGS:
        next_index = index + 1
    elif token.startswith("-"):
        raise GuardError("killall options cannot be proven runtime-safe")
    return next_index


def _parse_killall(argv: list[str]) -> KillallSpec:
    spec = KillallSpec()
    index = 1
    while index < len(argv):
        if argv[index] == "--":
            spec.names.extend(argv[index + 1 :])
            break
        next_index = _consume_killall_option(argv, index, spec)
        if next_index is None:
            spec.names.append(argv[index])
            index += 1
        else:
            index = next_index
    return spec


def _is_killall_inspection(argv: list[str]) -> bool:
    spec = _parse_killall(argv)
    return (
        spec.inspection
        or _signal_value(spec.signal_value) == "0"
        or not spec.names
    )


def _name_matches(record: ProcessRecord, name: str, spec: KillallSpec) -> bool:
    if spec.regex_mode:
        return _safe_pattern_matches(record, name, False, False, spec.ignore_case)
    process_name = os.path.basename(record.comm)
    if spec.ignore_case:
        process_name = process_name.casefold()
        name = name.casefold()
    return process_name == name


def _lineage_matches(lineage: list[ProcessRecord], spec: KillallSpec) -> bool:
    for record in lineage:
        if any(_name_matches(record, name, spec) for name in spec.names):
            return True
    return False


def _evaluate_killall(
    argv: list[str], lineage: list[ProcessRecord]
) -> dict[str, Any]:
    spec = _parse_killall(argv)
    if _is_killall_inspection(argv):
        return _allow("Process signal inspection does not terminate the runtime")
    if _lineage_matches(lineage, spec):
        return _forbid(
            "process.runtime-self-preservation",
            "Refusing a process-name termination that matches the current runtime lineage",
        )
    return _allow("Process-name termination does not match the runtime lineage")
