# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validated input model for the GitHub API efficiency benchmark."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any

from github_api_efficiency_evidence_validation import validate_evidence
from github_api_efficiency_metrics import (
    build_transport_metrics,
    counter_relationship_error,
)
from github_api_efficiency_schema import (  # noqa: F401  (re-exported)
    DISTRIBUTION_SAMPLE_FIELDS,
    EVIDENCE_GROUPS,
    EVIDENCE_SCHEMA,
    POPULATION_FIELDS,
    REPORT_COUNTERS,
    BenchmarkInputError,
    number as _number,
    require_object as _object,
)


TRANSPORT_SCHEMA_VERSION = 2
_ALLOWED_PATHS = frozenset(
    ("graphql", "rest", "search-graphql", "search-rest", "other", "unknown")
)
_RECONCILED_PATH_METRICS = (
    "attempted_requests",
    "known_quota_cost",
    "unknown_quota_cost_attempts",
)


@dataclass(frozen=True)
class Window:
    label: str
    report: dict[str, Any]
    evidence: dict[str, Any]
    transport_sha256: str
    evidence_sha256: str
    totals: dict[str, int]
    normalized: dict[str, dict[str, float | None]]



def _load_object(path: Path, role: str) -> tuple[dict[str, Any], str]:
    if path.is_symlink() or not path.is_file():
        raise BenchmarkInputError(
            f"{role} must be a regular, non-symlink file"
        )
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BenchmarkInputError(f"{role} is not readable JSON") from exc
    if not isinstance(payload, dict):
        raise BenchmarkInputError(f"{role} root must be an object")
    return payload, hashlib.sha256(raw).hexdigest()



def _validate_retained_window(meta: dict[str, Any]) -> None:
    first = _number(meta.get("first_retained_ts"), "transport._meta.first_retained_ts")
    last = _number(meta.get("last_retained_ts"), "transport._meta.last_retained_ts")
    duration = _number(
        meta.get("effective_window_seconds"),
        "transport._meta.effective_window_seconds",
    )
    if first <= 0 or last <= first or duration != last - first:
        raise BenchmarkInputError(
            "transport retained timestamps and effective duration are inconsistent"
        )
    if not isinstance(meta.get("attempts_exact"), bool):
        raise BenchmarkInputError("transport._meta.attempts_exact must be boolean")


def _validate_path_metrics(by_path: dict[str, Any]) -> dict[str, int]:
    totals = {metric: 0 for metric in _RECONCILED_PATH_METRICS}
    for path_name, path_metrics in by_path.items():
        if path_name not in _ALLOWED_PATHS:
            raise BenchmarkInputError("transport.by_path contains an unsupported path")
        if not isinstance(path_metrics, dict):
            raise BenchmarkInputError("transport.by_path entries must be objects")
        for metric in _RECONCILED_PATH_METRICS:
            value = _number(
                path_metrics.get(metric),
                f"transport.by_path.{path_name}.{metric}",
            )
            totals[metric] += int(value)
    return totals


def _validate_report(payload: dict[str, Any]) -> None:
    meta = _object(payload, "_meta", "transport")
    schema = _number(meta.get("schema_version"), "transport._meta.schema_version")
    if schema != TRANSPORT_SCHEMA_VERSION:
        raise BenchmarkInputError("transport report schema_version must be 2")
    for field in REPORT_COUNTERS:
        _number(meta.get(field), f"transport._meta.{field}")
    _validate_retained_window(meta)
    counter_error = counter_relationship_error(meta)
    if counter_error:
        raise BenchmarkInputError(counter_error)
    by_path = _object(payload, "by_path", "transport")
    path_totals = _validate_path_metrics(by_path)
    for metric, path_total in path_totals.items():
        if path_total != meta[metric]:
            raise BenchmarkInputError(
                f"transport {metric} does not reconcile by path"
            )



def load_transport_report(
    path: Path, role: str = "transport report"
) -> tuple[dict[str, Any], str]:
    """Load and validate one immutable schema-v2 transport report."""
    report, transport_sha256 = _load_object(path, role)
    _validate_report(report)
    return report, transport_sha256


def build_window(
    label: str, report_path: Path, evidence_path: Path
) -> Window:
    report, transport_sha256 = load_transport_report(
        report_path, f"{label} transport report"
    )
    evidence, evidence_sha256 = _load_object(
        evidence_path, f"{label} evidence"
    )
    validate_evidence(evidence, transport_sha256)
    totals, normalized = build_transport_metrics(report, evidence)
    return Window(
        label,
        report,
        evidence,
        transport_sha256,
        evidence_sha256,
        totals,
        normalized,
    )
