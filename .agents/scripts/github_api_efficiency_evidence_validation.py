# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence sidecar validation for the GitHub API efficiency benchmark."""

from __future__ import annotations

from typing import Any

from github_api_efficiency_schema import (
    DISTRIBUTION_SAMPLE_FIELDS,
    EVIDENCE_GROUPS,
    EVIDENCE_SCHEMA,
    POPULATION_FIELDS,
    _MEASURED_EVIDENCE_FIELDS,
    _SHA256_RE,
    BenchmarkInputError,
    number as _number,
    require_object as _object,
)


def _validate_evidence_relationships(payload: dict[str, Any]) -> None:
    population = payload["population"]
    path_budgets = payload["path_budgets"]
    constraints = (
        (
            population["unchanged_cycles"],
            population["pulse_cycles"],
            "evidence unchanged cycles exceed Pulse cycles",
        ),
        (
            population["unique_actionable_head_shas"],
            population["actionable_changes"],
            "evidence unique actionable head SHAs exceed actionable changes",
        ),
        (
            path_budgets["cycle_scoped_aggregate_check_fetches"],
            path_budgets["aggregate_check_fetches"],
            "evidence cycle-scoped aggregate check fetches exceed total fetches",
        ),
        (
            path_budgets["unique_cycle_scoped_actionable_heads"],
            population["actionable_changes"],
            "evidence cycle-scoped actionable heads exceed actionable observations",
        ),
    )
    for left, right, message in constraints:
        if None not in (left, right) and left > right:
            raise BenchmarkInputError(message)


def _validate_population(payload: dict[str, Any]) -> None:
    population = _object(payload, "population", "evidence")
    for field in POPULATION_FIELDS:
        if field not in population:
            raise BenchmarkInputError(f"evidence.population.{field} is required")
        _number(
            population[field],
            f"evidence.population.{field}",
            nullable=True,
        )
    if "repository_set_sha256" not in population:
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 is required"
        )
    population_hash = population["repository_set_sha256"]
    if population_hash is None:
        return
    if not isinstance(population_hash, str):
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 must be null or lowercase SHA-256"
        )
    if not _SHA256_RE.fullmatch(population_hash):
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 must be null or lowercase SHA-256"
        )


def _validate_evidence_groups(payload: dict[str, Any]) -> None:
    for group_name, fields in EVIDENCE_GROUPS.items():
        group = _object(payload, group_name, "evidence")
        for field in fields:
            if field not in group:
                raise BenchmarkInputError(
                    f"evidence.{group_name}.{field} is required"
                )
            _number(
                group[field],
                f"evidence.{group_name}.{field}",
                integer=(group_name, field) not in _MEASURED_EVIDENCE_FIELDS,
                nullable=True,
            )


def _validate_distribution_relationships(payload: dict[str, Any]) -> None:
    for (group_name, percentile_field), sample_field in (
        DISTRIBUTION_SAMPLE_FIELDS.items()
    ):
        samples = payload[group_name][sample_field]
        percentile = payload[group_name][percentile_field]
        context = f"evidence.{group_name}.{percentile_field}"
        if samples is None:
            if percentile is not None:
                raise BenchmarkInputError(f"{context} requires a sample count")
            continue
        if samples == 0 and percentile is not None:
            raise BenchmarkInputError(
                f"{context} must be null when its sample count is zero"
            )
        if samples > 0 and percentile is None:
            raise BenchmarkInputError(
                f"{context} is required when its sample count is positive"
            )


def validate_evidence(
    payload: dict[str, Any], transport_sha256: str
) -> None:
    if payload.get("schema") != EVIDENCE_SCHEMA:
        raise BenchmarkInputError(f"evidence schema must be {EVIDENCE_SCHEMA}")
    if payload.get("transport_sha256") != transport_sha256:
        raise BenchmarkInputError(
            "evidence transport_sha256 does not match the transport report"
        )
    if not isinstance(payload.get("complete"), bool):
        raise BenchmarkInputError("evidence.complete must be boolean")
    _validate_population(payload)
    _validate_evidence_groups(payload)
    _validate_distribution_relationships(payload)
    _validate_evidence_relationships(payload)
