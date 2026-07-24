#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared types and primitives for runtime process self-preservation."""

from __future__ import annotations

import os
import signal
from dataclasses import dataclass
from typing import Any

FORBID_EXIT = 20
TERMINATORS = {"kill", "killall", "pkill"}
SIGNAL_NAMES = {
    member.name.removeprefix("SIG") for member in signal.Signals
} | {"0"}
REGEX_META = frozenset(r".^$*+?{}[]\|()")


class GuardError(ValueError):
    """Raised when termination targets cannot be proven runtime-safe."""


class RuntimeIdentityError(GuardError):
    """Raised when authoritative runtime process evidence cannot be trusted."""


@dataclass(frozen=True)
class ProcessRecord:
    """One immutable process-table row."""

    pid: int
    ppid: int
    pgid: int
    start: str
    comm: str
    args: str


def _decision(decision: str, rule_id: str, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 2,
        "decision": decision,
        "rule_id": rule_id,
        "reason": reason,
    }


def _allow(reason: str) -> dict[str, Any]:
    return _decision("allow", "process.runtime-safe-target", reason)


def _forbid(rule_id: str, reason: str) -> dict[str, Any]:
    return _decision("forbid", rule_id, reason)


def _normalise_identity(value: str) -> str:
    return " ".join(value.split())


def _normalise_argv(argv: list[str]) -> list[str]:
    if not argv:
        return argv
    executable = os.path.basename(argv[0])
    if executable in {"busybox", "toybox"} and len(argv) > 1:
        if argv[1] in TERMINATORS:
            return argv[1:]
    return argv


def _signal_value(token: str) -> str | None:
    value = token.lstrip("-").upper().removeprefix("SIG")
    if value.isdigit() or value in SIGNAL_NAMES:
        return value
    return None


def _safe_pattern_matches(
    record: ProcessRecord,
    pattern: str,
    full: bool,
    exact: bool,
    ignore_case: bool,
) -> bool:
    if any(character in REGEX_META for character in pattern):
        raise GuardError(
            "process-name regular expressions cannot be proven portable"
        )
    value = record.args if full else os.path.basename(record.comm)
    if ignore_case:
        value = value.casefold()
        pattern = pattern.casefold()
    return value == pattern if exact else pattern in value
