# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Typed readers for GitHub API efficiency evidence event maps."""

from __future__ import annotations

from collections import Counter
from typing import Any, Callable

from github_api_efficiency_events import EvidenceBuildError, _non_negative_int
from github_api_efficiency_schema import _SHA256_RE


def parsed_values(
    events: dict[str, Counter[str]], name: str, parser: Callable[[str], Any]
) -> list[Any]:
    try:
        return [parser(value) for value in events.get(name, {})]
    except (TypeError, ValueError) as exc:
        raise EvidenceBuildError(f"evidence {name} contains an invalid value") from exc


def snapshot(
    events: dict[str, Counter[str]], name: str, parser: Callable[[str], Any]
) -> Any | None:
    values = parsed_values(events, name, parser)
    if not values:
        return None
    if len(set(values)) != 1:
        raise EvidenceBuildError(f"evidence {name} contains conflicting snapshots")
    return values[0]


def extreme_int(
    events: dict[str, Counter[str]], name: str, selector: Callable[[list[int]], int]
) -> int | None:
    values = parsed_values(events, name, int)
    if any(value < 0 for value in values):
        raise EvidenceBuildError(f"evidence {name} must be non-negative")
    return selector(values) if values else None


def sum_event(events: dict[str, Counter[str]], name: str) -> int:
    total = 0
    for value, count in events.get(name, {}).items():
        try:
            parsed = int(value)
        except ValueError as exc:
            raise EvidenceBuildError(
                f"evidence {name} contains an invalid integer"
            ) from exc
        number = _non_negative_int(parsed, f"evidence {name}")
        total += number * count
    return total


def unique_actionable_heads(
    events: dict[str, Counter[str]], actionable: int
) -> int | None:
    failures = sum_event(events, "population.actionable_head_hash_failures")
    if failures:
        return None
    tokens = events.get("population.actionable_head_token", {})
    legacy = events.get("population.unique_actionable_head_shas", {})
    if tokens and legacy:
        raise EvidenceBuildError("actionable head evidence mixes tokens and legacy counts")
    if tokens:
        if any(not _SHA256_RE.fullmatch(token) for token in tokens):
            raise EvidenceBuildError("actionable head tokens must be lowercase SHA-256")
        unique = len(tokens)
    elif legacy:
        unique = sum_event(events, "population.unique_actionable_head_shas")
    elif actionable:
        return None
    else:
        unique = 0
    if unique > actionable:
        raise EvidenceBuildError("unique actionable heads exceed actionable changes")
    return unique


def unique_cycle_scoped_actionable_heads(
    events: dict[str, Counter[str]], cycle_scoped_fetches: int
) -> int | None:
    failures = sum_event(
        events, "path_budgets.cycle_scoped_actionable_head_hash_failures"
    )
    if failures:
        return None
    tokens = events.get("path_budgets.cycle_scoped_actionable_head_token", {})
    if any(not _SHA256_RE.fullmatch(token) for token in tokens):
        raise EvidenceBuildError(
            "cycle-scoped actionable head tokens must be lowercase SHA-256"
        )
    if tokens:
        return len(tokens)
    return None if cycle_scoped_fetches else 0


def sample_percentile(
    events: dict[str, Counter[str]], name: str, percent: int
) -> int | None:
    samples = events.get(name, {})
    total = sum(samples.values())
    if total < 1:
        return None
    target = (total * percent + 99) // 100
    cumulative = 0
    for value in sorted(samples, key=int):
        number = _non_negative_int(int(value), f"evidence {name}")
        cumulative += samples[value]
        if cumulative >= target:
            return number
    raise EvidenceBuildError(f"evidence {name} percentile could not be computed")


def sample_count(events: dict[str, Counter[str]], name: str) -> int:
    return sum(events.get(name, {}).values())
