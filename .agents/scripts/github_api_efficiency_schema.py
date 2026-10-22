# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Schema constants and scalar validation for GitHub API efficiency inputs."""

from __future__ import annotations

import math
import re
from typing import Any


EVIDENCE_SCHEMA = "aidevops-github-api-efficiency-evidence/v3"
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
_MAX_SAFE_INTEGER = 9_007_199_254_740_991

REPORT_COUNTERS = (
    "attempted_requests",
    "retries",
    "pages",
    "additional_pages",
    "successful_attempts",
    "failed_attempts",
    "elapsed_ms",
    "unknown_elapsed_attempts",
    "known_quota_cost",
    "unknown_quota_cost_attempts",
    "duplicate_attempt_ids",
    "unidentified_attempts",
    "unknown_page_attempts",
    "window_malformed_v2_records",
    "legacy_events",
    "opaque_paginated_attempts",
)
POPULATION_FIELDS = (
    "repository_count",
    "pulse_cycles",
    "unchanged_cycles",
    "actionable_changes",
    "unique_actionable_head_shas",
)
EVIDENCE_GROUPS = {
    "latency": (
        "p50_ms",
        "p95_ms",
        "peak_attempts_per_minute",
        "completed_action_samples",
        "completed_action_p95_ms",
    ),
    "cache": ("fresh_hits", "fresh_empty_hits", "misses", "stale", "invalidated"),
    "single_flight": ("leaders", "waits", "takeovers", "duplicate_leaders"),
    "webhook": (
        "invalidations",
        "lag_samples",
        "lag_p50_ms",
        "lag_p95_ms",
        "duplicate_actions",
        "missed_recoveries",
    ),
    "guardrails": (
        "stale_snapshot_detections",
        "forced_live_refreshes",
        "stale_positive_decisions",
        "dispatch_dependency_violations",
        "required_check_merge_preflight_mismatches",
    ),
    "path_budgets": (
        "fingerprint_verification_list_calls",
        "fresh_empty_live_fallbacks",
        "aggregate_check_fetches",
        "cycle_scoped_aggregate_check_fetches",
        "unique_cycle_scoped_actionable_heads",
    ),
}
DISTRIBUTION_SAMPLE_FIELDS = {
    ("latency", "completed_action_p95_ms"): "completed_action_samples",
    ("webhook", "lag_p50_ms"): "lag_samples",
    ("webhook", "lag_p95_ms"): "lag_samples",
}
_MEASURED_EVIDENCE_FIELDS = frozenset(
    (
        ("latency", "p50_ms"),
        ("latency", "p95_ms"),
        ("latency", "completed_action_p95_ms"),
        ("webhook", "lag_p50_ms"),
        ("webhook", "lag_p95_ms"),
    )
)



class BenchmarkInputError(ValueError):
    """Raised when a report or evidence sidecar violates its schema."""



def number(
    value: Any,
    context: str,
    *,
    integer: bool = True,
    nullable: bool = False,
) -> int | float | None:
    if value is None:
        if nullable:
            return None
        raise BenchmarkInputError(f"{context} must be a non-negative number")
    expected = (int,) if integer else (int, float)
    if type(value) not in expected:
        raise BenchmarkInputError(f"{context} must be a non-negative number")
    if isinstance(value, float):
        if not math.isfinite(value):
            raise BenchmarkInputError(
                f"{context} must be a non-negative safe JSON number"
            )
    if not 0 <= value <= _MAX_SAFE_INTEGER:
        raise BenchmarkInputError(
            f"{context} must be a non-negative safe JSON number"
        )
    return value


def require_object(payload: dict[str, Any], key: str, context: str) -> dict[str, Any]:
    value = payload.get(key)
    if not isinstance(value, dict):
        raise BenchmarkInputError(f"{context}.{key} must be an object")
    return value
