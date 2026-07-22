#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pattern-based pkill command evaluation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from process_termination_common import (
    GuardError,
    ProcessRecord,
    _allow,
    _forbid,
    _safe_pattern_matches,
    _signal_value,
)

FLAG_ATTRIBUTES = {
    "-f": "full",
    "--full": "full",
    "-x": "exact",
    "--exact": "exact",
    "-i": "ignore_case",
    "--ignore-case": "ignore_case",
}
SELECTOR_OPTIONS = {"-P", "--parent", "-g", "--pgroup", "--signal"}


@dataclass
class PkillSpec:
    """Parsed pkill command state."""

    signal_value: str = "TERM"
    full: bool = False
    exact: bool = False
    ignore_case: bool = False
    parents: set[int] | None = None
    pgroups: set[int] | None = None
    pattern: str | None = None


def _parse_id_list(value: str) -> set[int]:
    values = value.split(",")
    if not values or any(not item.isdigit() for item in values):
        raise GuardError("process selector is ambiguous")
    return {int(item, 10) for item in values}


def _consume_selector(
    argv: list[str], index: int, spec: PkillSpec
) -> int | None:
    token = argv[index]
    if token not in SELECTOR_OPTIONS:
        return None
    if index + 1 >= len(argv):
        raise GuardError("process selector is incomplete")
    value = argv[index + 1]
    if token in {"-P", "--parent"}:
        spec.parents = _parse_id_list(value)
    elif token in {"-g", "--pgroup"}:
        spec.pgroups = _parse_id_list(value)
    else:
        spec.signal_value = value
    return index + 2


def _consume_pkill_option(
    argv: list[str], index: int, spec: PkillSpec
) -> int | None:
    token = argv[index]
    signal_value = _signal_value(token) if token.startswith("-") else None
    if signal_value is not None:
        spec.signal_value = signal_value
        return index + 1
    attribute = FLAG_ATTRIBUTES.get(token)
    if attribute:
        setattr(spec, attribute, True)
        return index + 1
    selector_index = _consume_selector(argv, index, spec)
    if selector_index is not None:
        return selector_index
    if token.startswith("--signal="):
        spec.signal_value = token.split("=", 1)[1]
        return index + 1
    if token.startswith("-"):
        raise GuardError("pkill options cannot be proven runtime-safe")
    return None


def _parse_pkill(argv: list[str]) -> PkillSpec:
    spec = PkillSpec()
    index = 1
    while index < len(argv):
        if argv[index] == "--":
            index += 1
            break
        next_index = _consume_pkill_option(argv, index, spec)
        if next_index is None:
            break
        index = next_index
    remaining = argv[index:]
    if len(remaining) > 1:
        raise GuardError("pkill has ambiguous process patterns")
    spec.pattern = remaining[0] if remaining else None
    return spec


def _is_pkill_inspection(argv: list[str]) -> bool:
    spec = _parse_pkill(argv)
    return _signal_value(spec.signal_value) == "0" or spec.pattern is None


def _selected(record: ProcessRecord, spec: PkillSpec) -> bool:
    if spec.parents is not None and record.ppid not in spec.parents:
        return False
    if spec.pgroups is not None and record.pgid not in spec.pgroups:
        return False
    return True


def _evaluate_pkill(
    argv: list[str], lineage: list[ProcessRecord]
) -> dict[str, Any]:
    spec = _parse_pkill(argv)
    if _is_pkill_inspection(argv):
        return _allow("Process signal inspection does not terminate the runtime")
    if spec.pgroups is not None and 0 in spec.pgroups:
        spec.pgroups = (spec.pgroups - {0}) | {lineage[0].pgid}
    for record in lineage:
        if not _selected(record, spec):
            continue
        if _safe_pattern_matches(
            record,
            spec.pattern or "",
            spec.full,
            spec.exact,
            spec.ignore_case,
        ):
            return _forbid(
                "process.runtime-self-preservation",
                "Refusing a process-name termination that matches the current runtime lineage",
            )
    return _allow("Process-name termination does not match the runtime lineage")
