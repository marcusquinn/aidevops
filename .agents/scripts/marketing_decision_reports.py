#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed, aggregate decision reports and independently labelled evaluations."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

SCHEMA = "aidevops.marketing-decision-report/v1"
EVALUATION_SCHEMA = "aidevops.marketing-decision-evaluation/v1"
OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")


class DecisionReportError(ValueError):
    """Raised when a decision report cannot be supported by its evidence."""


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DecisionReportError(f"{field} must be an object")
    return value


def _list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise DecisionReportError(f"{field} must be an array")
    return value


def _opaque(value: Any, field: str) -> str:
    if not isinstance(value, str) or not OPAQUE.fullmatch(value):
        raise DecisionReportError(f"{field} must be an opaque identifier")
    return value


def _timestamp(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise DecisionReportError(f"{field} must be a UTC timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise DecisionReportError(f"{field} must be a UTC timestamp") from exc
    return value


def _amount(value: Any, field: str) -> Decimal | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise DecisionReportError(f"{field} must be a non-negative amount or null")
    try:
        amount = Decimal(str(value))
    except InvalidOperation as exc:
        raise DecisionReportError(f"{field} must be a non-negative amount or null") from exc
    if not amount.is_finite() or amount < 0:
        raise DecisionReportError(f"{field} must be a non-negative amount or null")
    return amount


def _wire(value: Decimal | None) -> str | None:
    return None if value is None else format(value.normalize(), "f")


def _digest(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def _currency(value: Any, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Z]{3}", value):
        raise DecisionReportError(f"{field} must be an ISO 4217 currency")
    return value


def build_report(document: Any) -> dict[str, Any]:
    """Build a source-linked report without inventing economics or causality."""
    data = _object(document, "input")
    if data.get("schema") != SCHEMA:
        raise DecisionReportError("input schema is unsupported")
    as_of = _timestamp(data.get("as_of"), "as_of")
    window = _object(data.get("time_window"), "time_window")
    start = _timestamp(window.get("start"), "time_window.start")
    end = _timestamp(window.get("end"), "time_window.end")
    if start > end or end > as_of:
        raise DecisionReportError("time_window must end at or before as_of")
    currency = _currency(data.get("currency"), "currency")
    sources = _list(data.get("sources"), "sources")
    source_ids = {_opaque(_object(source, "source").get("source_id"), "source_id") for source in sources}
    if not source_ids:
        raise DecisionReportError("sources must not be empty")
    recommendations = _list(data.get("recommendations"), "recommendations")
    rendered: list[dict[str, Any]] = []
    for recommendation in recommendations:
        row = _object(recommendation, "recommendation")
        source_id = _opaque(row.get("source_id"), "recommendation.source_id")
        if source_id not in source_ids:
            raise DecisionReportError("recommendation source_id is not declared")
        confidence = row.get("confidence")
        if confidence is not None and (isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1):
            raise DecisionReportError("recommendation confidence must be between zero and one")
        calibration = row.get("calibration", "reported")
        if calibration not in {"calibrated", "reported", "unknown"}:
            raise DecisionReportError("recommendation calibration is unsupported")
        economics = _object(row.get("economics", {}), "recommendation.economics")
        measured = _amount(economics.get("measured"), "economics.measured")
        estimated = _amount(economics.get("estimated"), "economics.estimated")
        known_cost = _amount(economics.get("known_cost"), "economics.known_cost")
        if economics.get("currency", currency) != currency:
            raise DecisionReportError("recommendation economics currency contradicts report currency")
        rendered.append({
            "recommendation_id": _opaque(row.get("recommendation_id"), "recommendation_id"),
            "source_id": source_id,
            "family": _opaque(row.get("family"), "recommendation.family"),
            "engine": None if row.get("engine") is None else _opaque(row.get("engine"), "recommendation.engine"),
            "status": row.get("status", "inconclusive"),
            "confidence": confidence,
            "confidence_status": calibration,
            "economics": {"currency": currency, "measured": _wire(measured), "estimated": _wire(estimated), "known_cost": _wire(known_cost), "unknown_components": _list(economics.get("unknown_components", []), "economics.unknown_components")},
            "assumptions": _list(row.get("assumptions", []), "recommendation.assumptions"),
        })
    rendered.sort(key=lambda item: (item["engine"] or "", item["recommendation_id"]))
    return {"schema": SCHEMA, "identity": _digest({"as_of": as_of, "window": window, "sources": sorted(source_ids)}), "as_of": as_of, "time_window": {"start": start, "end": end}, "currency": currency, "causality": "observational_unless_separately_approved_experiment", "recommendations": rendered, "source_ids": sorted(source_ids)}


def _holdout_labels(document: Any) -> list[Any]:
    """Validate the sole permitted ground-truth source for evaluation."""
    data = _object(document, "input")
    if data.get("schema") != EVALUATION_SCHEMA:
        raise DecisionReportError("evaluation schema is unsupported")
    labels = _list(data.get("labels"), "labels")
    if not labels:
        raise DecisionReportError("labels must not be empty")
    return labels


def _accumulate_holdout(labels: list[Any]) -> tuple[dict[str, int], Decimal | None, Decimal | None]:
    """Count reviewed outcomes while preserving missing cost and time evidence."""
    counts = {key: 0 for key in ("accepted", "repaired", "rejected", "abstained", "false_acceptance")}
    total_cost: Decimal | None = Decimal("0")
    total_time: Decimal | None = Decimal("0")
    for label in labels:
        row = _object(label, "label")
        if row.get("provenance") != "independent_human" or row.get("synthetic") or row.get("model_generated_ground_truth"):
            raise DecisionReportError("holdout labels must be independent human ground truth, never synthetic or model-generated")
        outcome = row.get("outcome")
        if outcome not in counts:
            raise DecisionReportError("label outcome is unsupported")
        counts[outcome] += 1
        for field, accumulator in (("total_known_cost", "cost"), ("end_to_end_seconds", "time")):
            value = _amount(row.get(field), field)
            if value is None:
                if accumulator == "cost": total_cost = None
                elif total_time is not None: total_time = None
            elif accumulator == "cost" and total_cost is not None: total_cost += value
            elif accumulator == "time" and total_time is not None: total_time += value
    return counts, total_cost, total_time


def evaluate_holdout(document: Any) -> dict[str, Any]:
    """Evaluate only independent human-labelled holdouts; synthetic data is wiring-only."""
    labels = _holdout_labels(document)
    counts, total_cost, total_time = _accumulate_holdout(labels)
    attempted = len(labels) - counts["abstained"]
    accepted = counts["accepted"] + counts["repaired"]
    return {"schema": EVALUATION_SCHEMA, "identity": _digest(labels), "labels": len(labels), "coverage": attempted / len(labels), "accepted_or_repaired": accepted, "rejected": counts["rejected"], "abstained": counts["abstained"], "false_acceptance": counts["false_acceptance"], "calibration": "not_claimed_without_predeclared_bins", "total_known_cost": _wire(total_cost), "end_to_end_seconds": _wire(total_time), "outcome_boundary": "holdout_only; no provider benchmark, ROI, or causal claim"}
