#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Parse typed, privacy-safe GitHub API efficiency evidence events."""

from __future__ import annotations

from collections import Counter, defaultdict
import re
from typing import Any


_EVENT_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,95}$")
_VALUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


class EvidenceBuildError(ValueError):
    """Raised when evidence events contradict the sidecar contract."""


def _non_negative_int(value: Any, context: str) -> int:
    if type(value) is not int or value < 0:
        raise EvidenceBuildError(f"{context} must be a non-negative integer")
    return value


def _event_map(report: dict[str, Any]) -> dict[str, Counter[str]]:
    decisions = report.get("by_route_decision")
    if not isinstance(decisions, dict):
        raise EvidenceBuildError("transport by_route_decision must be an object")
    events: defaultdict[str, Counter[str]] = defaultdict(Counter)
    for decision, metrics in decisions.items():
        if not isinstance(decision, str) or not decision.startswith("evidence:"):
            continue
        parts = decision.split(":", 2)
        if len(parts) != 3 or not _EVENT_RE.fullmatch(parts[1]):
            raise EvidenceBuildError("transport contains an invalid evidence event name")
        if not _VALUE_RE.fullmatch(parts[2]):
            raise EvidenceBuildError("transport contains an invalid evidence event value")
        if not isinstance(metrics, dict):
            raise EvidenceBuildError("transport evidence metrics must be objects")
        count = _non_negative_int(
            metrics.get("evidence_events"), f"evidence event {parts[1]} count"
        )
        if count < 1:
            raise EvidenceBuildError(
                "evidence-prefixed decisions must be typed evidence events"
            )
        events[parts[1]][parts[2]] += count
    return dict(events)
