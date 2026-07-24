#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Transport metric normalization for the GitHub API efficiency benchmark."""

from __future__ import annotations

from typing import Any


TRANSPORT_METRICS = (
    "attempted_requests",
    "graphql_points",
    "graphql_attempts",
    "rest_attempts",
    "search_attempts",
    "other_attempts",
    "retries",
    "pages",
    "additional_pages",
    "api_errors",
)


def counter_relationship_error(meta: dict[str, Any]) -> str | None:
    attempts = meta["attempted_requests"]
    checks = (
        (
            meta["successful_attempts"] + meta["failed_attempts"] == attempts,
            "transport successful and failed attempts do not reconcile",
        ),
        (meta["retries"] <= attempts, "transport retries exceed attempts"),
        (meta["pages"] <= attempts, "transport pages exceed attempts"),
        (
            meta["additional_pages"] <= meta["pages"],
            "transport additional pages exceed pages",
        ),
        (
            meta["unknown_quota_cost_attempts"] <= attempts,
            "transport unknown quota attempts exceed attempts",
        ),
    )
    for valid, message in checks:
        if not valid:
            return message
    return None


def _path_metric(
    report: dict[str, Any], path_name: str, metric: str
) -> int:
    path_metrics = report["by_path"].get(path_name, {})
    value = path_metrics.get(metric, 0)
    return int(value) if isinstance(value, int) and not isinstance(value, bool) else 0


def _transport_totals(report: dict[str, Any]) -> dict[str, int]:
    meta = report["_meta"]
    graphql_paths = ("graphql", "search-graphql")
    graphql_points = sum(
        _path_metric(report, path, "known_quota_cost")
        for path in graphql_paths
    )
    graphql_attempts = sum(
        _path_metric(report, path, "attempted_requests")
        for path in graphql_paths
    )
    search_attempts = sum(
        _path_metric(report, path, "attempted_requests")
        for path in ("search-graphql", "search-rest")
    )
    return {
        "attempted_requests": meta["attempted_requests"],
        "graphql_points": graphql_points,
        "graphql_attempts": graphql_attempts,
        "rest_attempts": _path_metric(report, "rest", "attempted_requests"),
        "search_attempts": search_attempts,
        "other_attempts": sum(
            _path_metric(report, path, "attempted_requests")
            for path in ("other", "unknown")
        ),
        "retries": meta["retries"],
        "pages": meta["pages"],
        "additional_pages": meta["additional_pages"],
        "api_errors": meta["failed_attempts"],
    }


def _divide(
    value: int, denominator: float | int | None
) -> float | None:
    if denominator is None or denominator <= 0:
        return None
    return value / denominator


def _normalise(
    report: dict[str, Any],
    evidence: dict[str, Any],
    totals: dict[str, int],
) -> dict[str, dict[str, float | None]]:
    population = evidence["population"]
    duration_hours = report["_meta"]["effective_window_seconds"] / 3600
    repository_count = population["repository_count"]
    repo_hours = (
        repository_count * duration_hours
        if repository_count is not None
        else None
    )
    denominators = {
        "per_repo_hour": repo_hours,
        "per_pulse_cycle": population["pulse_cycles"],
        "per_unchanged_cycle": population["unchanged_cycles"],
        "per_actionable_change": population["actionable_changes"],
        "per_unique_head_sha": population["unique_actionable_head_shas"],
    }
    return {
        name: {
            metric: _divide(totals[metric], denominator)
            for metric in TRANSPORT_METRICS
        }
        for name, denominator in denominators.items()
    }


def build_transport_metrics(
    report: dict[str, Any], evidence: dict[str, Any]
) -> tuple[dict[str, int], dict[str, dict[str, float | None]]]:
    totals = _transport_totals(report)
    return totals, _normalise(report, evidence, totals)
