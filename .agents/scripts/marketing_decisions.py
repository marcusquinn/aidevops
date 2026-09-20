#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Provider-neutral validation and offline marketing decision execution."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol

INPUT_SCHEMA = "aidevops.marketing-decision-input/v1"
DECISIONS_SCHEMA = "aidevops.marketing-decision-supplied/v1"
REPORT_SCHEMA = "aidevops.marketing-decision-report/v1"
MAX_INPUT_BYTES = 1_048_576
MAX_ROWS = 1_000
MAX_CANDIDATES = 100
MAX_CONCURRENCY = 16
OPAQUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
SHA256_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
DECISION_KINDS = {"choice", "score", "multi_label"}
CLASSIFICATIONS = {"public", "internal", "confidential"}
CONFIDENCE_PROVENANCE = {"reported", "calibrated", "unknown"}


class DecisionError(ValueError):
    """Raised when a decision document fails closed."""


class DecisionAdapter(Protocol):
    """Narrow adapter implemented by an already-authorized host runtime."""

    def decide(self, request: dict[str, Any]) -> dict[str, Any]:
        """Return an aidevops.marketing-decision-supplied/v1 document."""


@dataclass(frozen=True)
class ValidatedRequest:
    """Validated input plus deterministic identity fields."""

    document: dict[str, Any]
    input_digest: str
    cache_key: str


def canonical_json(value: Any) -> str:
    """Serialize JSON deterministically and reject non-finite values."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value: Any) -> str:
    """Return a canonical content digest."""
    return "sha256:" + hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DecisionError(f"{field} must be an object")
    return value


def _list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise DecisionError(f"{field} must be an array")
    return value


def _opaque(value: Any, field: str) -> str:
    if not isinstance(value, str) or not OPAQUE_RE.fullmatch(value):
        raise DecisionError(f"{field} must be an opaque identifier")
    return value


def _timestamp(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise DecisionError(f"{field} must be a UTC timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise DecisionError(f"{field} must be a UTC timestamp") from error
    return value


def _number(value: Any, field: str, minimum: float = 0) -> float | int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DecisionError(f"{field} must be a number")
    if not math.isfinite(value) or value < minimum:
        raise DecisionError(f"{field} is outside the supported range")
    return value


def _bounded_int(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise DecisionError(f"{field} must be an integer")
    if not minimum <= value <= maximum:
        raise DecisionError(f"{field} is outside the supported range")
    return value


def _keys(value: dict[str, Any], required: set[str], allowed: set[str], field: str) -> None:
    if not required <= set(value):
        raise DecisionError(f"{field} is missing required fields")
    if set(value) - allowed:
        raise DecisionError(f"{field} contains unknown fields")


def _optional_metric(value: Any, field: str) -> float | int | None:
    return None if value is None else _number(value, field)


def _optional_integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise DecisionError(f"{field} must be a non-negative integer or null")
    return value


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise DecisionError(message)


def load_json(path: str | Path, maximum: int = MAX_INPUT_BYTES) -> Any:
    """Load one bounded JSON document."""
    with Path(path).open("rb") as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise DecisionError("input exceeds byte budget")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise DecisionError("input is not valid JSON") from error


def _validate_scope(scope: Any) -> dict[str, str]:
    scope = _object(scope, "scope")
    _keys(scope, {"project_id", "account_id"}, {"project_id", "account_id", "site_id"}, "scope")
    return {key: _opaque(value, f"scope.{key}") for key, value in scope.items()}


def _validate_versioned(value: Any, field: str, extra: set[str] | None = None) -> dict[str, str]:
    value = _object(value, field)
    allowed = {"id", "version"} | (extra or set())
    _keys(value, {"id", "version"}, allowed, field)
    return {key: _opaque(item, f"{field}.{key}") for key, item in value.items()}


def _validate_limits(value: Any) -> dict[str, Any]:
    value = _object(value, "limits")
    required = {"max_rows", "max_candidates_per_row", "max_concurrency", "budget"}
    _keys(value, required, required, "limits")
    budget = _object(value["budget"], "limits.budget")
    budget_fields = {"max_latency_ms", "max_input_tokens", "max_output_tokens", "max_cost_usd"}
    _keys(budget, budget_fields, budget_fields, "limits.budget")
    normalized_budget = {
        key: _optional_metric(item, f"limits.budget.{key}") for key, item in budget.items()
    }
    return {
        "max_rows": _bounded_int(value["max_rows"], "limits.max_rows", 1, MAX_ROWS),
        "max_candidates_per_row": _bounded_int(
            value["max_candidates_per_row"], "limits.max_candidates_per_row", 1, MAX_CANDIDATES
        ),
        "max_concurrency": _bounded_int(
            value["max_concurrency"], "limits.max_concurrency", 1, MAX_CONCURRENCY
        ),
        "budget": normalized_budget,
    }


def _validate_row(value: Any, limits: dict[str, Any], seen: set[str], field: str) -> dict[str, Any]:
    row = _object(value, field)
    required = {"row_id", "source", "decision_kind", "candidates"}
    _keys(row, required, required, field)
    row_id = _opaque(row["row_id"], f"{field}.row_id")
    if row_id in seen:
        raise DecisionError("row IDs must be unique")
    seen.add(row_id)
    source = _object(row["source"], f"{field}.source")
    _keys(source, {"source_id", "span"}, {"source_id", "span"}, f"{field}.source")
    normalized_source = {
        "source_id": _opaque(source["source_id"], f"{field}.source.source_id"),
        "span": _opaque(source["span"], f"{field}.source.span"),
    }
    kind = row["decision_kind"]
    if kind not in DECISION_KINDS:
        raise DecisionError(f"{field}.decision_kind is unsupported")
    candidates = _list(row["candidates"], f"{field}.candidates")
    if not candidates or len(candidates) > limits["max_candidates_per_row"]:
        raise DecisionError(f"{field}.candidates exceeds bounds")
    candidate_ids = [_opaque(item, f"{field}.candidates[]") for item in candidates]
    if len(candidate_ids) != len(set(candidate_ids)):
        raise DecisionError(f"{field}.candidates must be unique")
    return {"row_id": row_id, "source": normalized_source, "decision_kind": kind, "candidates": candidate_ids}


def validate_input(value: Any) -> ValidatedRequest:
    """Validate and normalize one bounded multi-domain request."""
    data = _object(value, "input")
    required = {
        "schema", "request_id", "scope", "captured_at", "as_of", "performance_window",
        "data_classification", "rubric", "model", "limits", "batches",
    }
    allowed = required | {"input_digest"}
    _keys(data, required, allowed, "input")
    if data["schema"] != INPUT_SCHEMA:
        raise DecisionError("unknown input schema version")
    scope = _validate_scope(data["scope"])
    window = _object(data["performance_window"], "performance_window")
    _keys(window, {"start", "end"}, {"start", "end"}, "performance_window")
    normalized_window = {
        "start": _timestamp(window["start"], "performance_window.start"),
        "end": _timestamp(window["end"], "performance_window.end"),
    }
    if normalized_window["start"] >= normalized_window["end"]:
        raise DecisionError("performance window must increase")
    classification = data["data_classification"]
    if classification not in CLASSIFICATIONS:
        raise DecisionError("unsupported data classification")
    limits = _validate_limits(data["limits"])
    seen: set[str] = set()
    batches = []
    for batch_index, raw_batch in enumerate(_list(data["batches"], "batches")):
        field = f"batches[{batch_index}]"
        batch = _object(raw_batch, field)
        _keys(batch, {"batch_id", "domain", "rows"}, {"batch_id", "domain", "rows"}, field)
        rows = [
            _validate_row(row, limits, seen, f"{field}.rows[{index}]")
            for index, row in enumerate(_list(batch["rows"], f"{field}.rows"))
        ]
        if not rows:
            raise DecisionError(f"{field}.rows cannot be empty")
        batches.append({
            "batch_id": _opaque(batch["batch_id"], f"{field}.batch_id"),
            "domain": _opaque(batch["domain"], f"{field}.domain"),
            "rows": rows,
        })
    if not batches or len(seen) > limits["max_rows"]:
        raise DecisionError("request row count exceeds bounds")
    rubric = _validate_versioned(data["rubric"], "rubric")
    model = _validate_versioned(data["model"], "model", {"provider"})
    _require("provider" in model, "model.provider is required")
    normalized = {
        "schema": INPUT_SCHEMA,
        "request_id": _opaque(data["request_id"], "request_id"),
        "scope": scope,
        "captured_at": _timestamp(data["captured_at"], "captured_at"),
        "as_of": _timestamp(data["as_of"], "as_of"),
        "performance_window": normalized_window,
        "data_classification": classification,
        "rubric": rubric,
        "model": model,
        "limits": limits,
        "batches": batches,
    }
    input_digest = digest(normalized)
    supplied_digest = data.get("input_digest")
    if supplied_digest is not None and (not SHA256_RE.fullmatch(supplied_digest) or supplied_digest != input_digest):
        raise DecisionError("input_digest does not match normalized input")
    cache_identity = {
        "scope": scope,
        "input_digest": input_digest,
        "rubric": normalized["rubric"],
        "model": normalized["model"],
        "performance_window": normalized_window,
    }
    return ValidatedRequest(normalized, input_digest, digest(cache_identity))


def validate_supplied(value: Any, request: ValidatedRequest) -> dict[str, Any]:
    """Validate supplied offline decisions before evaluating individual rows."""
    data = _object(value, "decisions")
    required = {"schema", "request_id", "input_digest", "decisions"}
    allowed = required | {"cancelled_after_row_id"}
    _keys(data, required, allowed, "decisions")
    if data["schema"] != DECISIONS_SCHEMA:
        raise DecisionError("unknown supplied-decision schema version")
    if data["request_id"] != request.document["request_id"]:
        raise DecisionError("decision request_id does not match input")
    if data["input_digest"] != request.input_digest:
        raise DecisionError("decision input_digest does not match input")
    rows = _list(data["decisions"], "decisions.decisions")
    normalized = []
    seen: set[str] = set()
    for index, raw in enumerate(rows):
        item = _object(raw, f"decisions[{index}]")
        row_id = _opaque(item.get("row_id"), f"decisions[{index}].row_id")
        if row_id in seen:
            raise DecisionError("supplied decision row IDs must be unique")
        seen.add(row_id)
        normalized.append(item)
    known = {row["row_id"] for batch in request.document["batches"] for row in batch["rows"]}
    if seen - known:
        raise DecisionError("supplied decisions contain unknown row IDs")
    cancelled = data.get("cancelled_after_row_id")
    if cancelled is not None and cancelled not in known:
        raise DecisionError("cancelled_after_row_id is unknown")
    return {"decisions": normalized, "cancelled_after_row_id": cancelled}


def _usage(value: Any) -> dict[str, float | int | None]:
    value = _object(value, "decision.usage")
    fields = {"latency_ms", "input_tokens", "output_tokens", "cost_usd"}
    _keys(value, fields, fields, "decision.usage")
    return {
        "latency_ms": _optional_metric(value["latency_ms"], "decision.usage.latency_ms"),
        "input_tokens": _optional_integer(value["input_tokens"], "decision.usage.input_tokens"),
        "output_tokens": _optional_integer(value["output_tokens"], "decision.usage.output_tokens"),
        "cost_usd": _optional_metric(value["cost_usd"], "decision.usage.cost_usd"),
    }


def _validate_action(value: Any, candidates: set[str]) -> dict[str, Any] | None:
    if value is None:
        return None
    action = _object(value, "decision.action_proposal")
    allowed = {"kind", "candidate_ids", "summary", "non_mutating"}
    _keys(action, {"kind", "candidate_ids", "non_mutating"}, allowed, "decision.action_proposal")
    ids = [_opaque(item, "decision.action_proposal.candidate_ids[]") for item in _list(action["candidate_ids"], "candidate_ids")]
    if action["kind"] != "recommendation" or action["non_mutating"] is not True or not set(ids) <= candidates:
        raise DecisionError("action proposal exceeds recommendation authority")
    summary = action.get("summary")
    if summary is not None:
        if not isinstance(summary, str) or len(summary) > 500 or "://" in summary or "$(" in summary:
            raise DecisionError("action proposal summary is unsafe")
    return {"kind": "recommendation", "candidate_ids": ids, "summary": summary, "non_mutating": True}


def _choice_value(value: Any, candidates: set[str]) -> Any:
    _require(value in candidates, "choice is not an observed candidate")
    return value


def _multi_label_value(value: Any, candidates: set[str]) -> list[Any]:
    labels = _list(value, "decision.value")
    _require(bool(labels) and set(labels) <= candidates, "multi-label value contains invalid candidates")
    _require(len(labels) == len(set(labels)), "multi-label value contains duplicate candidates")
    return labels


def _score_value(value: Any, _candidates: set[str]) -> float | int:
    return _number(value, "decision.value")


def _unit_interval(value: Any, field: str) -> float | int | None:
    if value is None:
        return None
    normalized = _number(value, field)
    _require(normalized <= 1, f"{field} must be between zero and one")
    return normalized


def _calibration(value: Any) -> dict[str, str | None]:
    calibration = _object(value, "decision.calibration")
    _keys(calibration, {"provenance", "reference"}, {"provenance", "reference"}, "decision.calibration")
    provenance = calibration["provenance"]
    _require(provenance in CONFIDENCE_PROVENANCE, "unsupported calibration provenance")
    reference = calibration["reference"]
    normalized_reference = None if reference is None else _opaque(reference, "decision.calibration.reference")
    return {"provenance": provenance, "reference": normalized_reference}


def _decision_value(value: Any, abstention: Any, row: dict[str, Any], candidates: set[str]) -> Any:
    if abstention is not None:
        _opaque(abstention, "decision.abstention_reason")
        _require(value is None, "abstained decisions must have a null value")
        return None
    validators = {"choice": _choice_value, "multi_label": _multi_label_value, "score": _score_value}
    return validators[row["decision_kind"]](value, candidates)


def _validate_decision(value: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    required = {"row_id", "kind", "value", "probability", "confidence", "calibration", "abstention_reason", "action_proposal", "usage"}
    _keys(value, required, required, "decision")
    _require(
        value["row_id"] == row["row_id"] and value["kind"] == row["decision_kind"],
        "decision identity or kind does not match row",
    )
    candidates = set(row["candidates"])
    abstention = value["abstention_reason"]
    decision_value = _decision_value(value["value"], abstention, row, candidates)
    probability = _unit_interval(value["probability"], "decision.probability")
    _require(row["decision_kind"] != "score" or probability is None, "a score is not a probability")
    return {
        "row_id": row["row_id"],
        "kind": row["decision_kind"],
        "value": decision_value,
        "probability": probability,
        "confidence": _unit_interval(value["confidence"], "decision.confidence"),
        "calibration": _calibration(value["calibration"]),
        "abstention_reason": abstention,
        "action_proposal": _validate_action(value["action_proposal"], candidates),
        "usage": _usage(value["usage"]),
    }


def _budget_reason(total: dict[str, float | int | None], limits: dict[str, Any]) -> str | None:
    mapping = {
        "latency_ms": "max_latency_ms",
        "input_tokens": "max_input_tokens",
        "output_tokens": "max_output_tokens",
        "cost_usd": "max_cost_usd",
    }
    for metric, limit_name in mapping.items():
        limit = limits[limit_name]
        if limit is not None and total[metric] is None:
            return "budget_usage_unknown"
        if limit is not None and total[metric] is not None and total[metric] > limit:
            return "budget_exceeded"
    return None


def _add_usage(total: dict[str, float | int | None], usage: dict[str, float | int | None]) -> dict[str, float | int | None]:
    result = {}
    for key in total:
        result[key] = None if total[key] is None or usage[key] is None else total[key] + usage[key]
    return result


def _evaluated_result(
    base: dict[str, Any],
    raw: dict[str, Any],
    row: dict[str, Any],
    usage: dict[str, float | int | None],
    budget: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, float | int | None]]:
    try:
        decision = _validate_decision(raw, row)
    except DecisionError:
        return {**base, "status": "failed", "reason": "invalid_decision", "decision": None}, usage
    projected = _add_usage(usage, decision["usage"])
    reason = _budget_reason(projected, budget)
    if reason:
        return {**base, "status": "deferred", "reason": reason, "decision": decision}, projected
    reason = "abstained" if decision["abstention_reason"] is not None else None
    status = "deferred" if reason else "accepted"
    return {**base, "status": status, "reason": reason, "decision": decision}, projected


def _run_row(
    batch: dict[str, Any],
    row: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    state: dict[str, Any],
    budget: dict[str, Any],
    cancel_after: str | None,
) -> dict[str, Any]:
    base = {
        "batch_id": batch["batch_id"],
        "domain": batch["domain"],
        "row_id": row["row_id"],
        "source": row["source"],
    }
    raw = by_id.get(row["row_id"])
    stopped_reason = "cancelled" if state["cancelled"] else state["budget_stopped"]
    if stopped_reason is not None or raw is None:
        reason = stopped_reason or "missing_decision"
        result = {**base, "status": "deferred", "reason": reason, "decision": None}
    else:
        result, state["usage"] = _evaluated_result(base, raw, row, state["usage"], budget)
        if result["reason"] in {"budget_exceeded", "budget_usage_unknown"}:
            state["budget_stopped"] = result["reason"]
    state["cancelled"] = state["cancelled"] or row["row_id"] == cancel_after
    return result


def run(request: ValidatedRequest, supplied: dict[str, Any]) -> dict[str, Any]:
    """Evaluate supplied decisions without network access or workflow mutation."""
    by_id = {item["row_id"]: item for item in supplied["decisions"]}
    state: dict[str, Any] = {
        "usage": {"latency_ms": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0},
        "cancelled": False,
        "budget_stopped": None,
    }
    budget = request.document["limits"]["budget"]
    results = [
        _run_row(batch, row, by_id, state, budget, supplied["cancelled_after_row_id"])
        for batch in request.document["batches"]
        for row in batch["rows"]
    ]
    usage = state["usage"]
    accepted = sum(item["status"] == "accepted" for item in results)
    return {
        "schema": REPORT_SCHEMA,
        "request_id": request.document["request_id"],
        "scope": request.document["scope"],
        "input_digest": request.input_digest,
        "cache_key": request.cache_key,
        "rubric": request.document["rubric"],
        "model": request.document["model"],
        "performance_window": request.document["performance_window"],
        "data_classification": request.document["data_classification"],
        "status": "complete" if accepted == len(results) else "partial",
        "results": results,
        "checkpoint": {
            "accepted": accepted,
            "deferred": sum(item["status"] == "deferred" for item in results),
            "failed": sum(item["status"] == "failed" for item in results),
            "remaining_row_ids": [item["row_id"] for item in results if item["status"] != "accepted"],
        },
        "metrics": {**usage, "cost_measurement": "unknown" if usage["cost_usd"] is None else "reported"},
        "authority": "non_mutating_recommendations_only",
    }


def _expected_rows(request: ValidatedRequest) -> dict[str, tuple[dict[str, Any], dict[str, Any]]]:
    return {
        row["row_id"]: (batch, row)
        for batch in request.document["batches"]
        for row in batch["rows"]
    }


def _validate_report_result(item: Any, expected: tuple[dict[str, Any], dict[str, Any]]) -> None:
    item = _object(item, "report.result")
    required = {"batch_id", "domain", "row_id", "source", "status", "reason", "decision"}
    _keys(item, required, required, "report.result")
    batch, row = expected
    _require(
        item["batch_id"] == batch["batch_id"]
        and item["domain"] == batch["domain"]
        and item["source"] == row["source"],
        "report result provenance does not match request",
    )
    _require(item["status"] in {"accepted", "deferred", "failed"}, "report result status is invalid")
    decision = item["decision"]
    if decision is None:
        _require(item["status"] != "accepted", "accepted report result must contain a decision")
        return
    normalized = _validate_decision(decision, row)
    _require(normalized == decision, "report decision is not normalized")
    _require(
        item["status"] != "accepted" or decision["abstention_reason"] is None,
        "accepted report result cannot be an abstention",
    )


def _validate_report_request(report: dict[str, Any], request: ValidatedRequest) -> None:
    expected_identity = {
        "request_id": request.document["request_id"],
        "scope": request.document["scope"],
        "input_digest": request.input_digest,
        "cache_key": request.cache_key,
        "rubric": request.document["rubric"],
        "model": request.document["model"],
        "performance_window": request.document["performance_window"],
        "data_classification": request.document["data_classification"],
    }
    _require(
        all(report[key] == expected for key, expected in expected_identity.items()),
        "report identity does not match request",
    )
    expected_rows = _expected_rows(request)
    results = _list(report["results"], "report.results")
    result_ids = [item.get("row_id") for item in results if isinstance(item, dict)]
    _require(set(result_ids) == set(expected_rows) and len(result_ids) == len(expected_rows), "report rows do not match request")
    for item in results:
        _validate_report_result(item, expected_rows[item["row_id"]])


def _validate_report_summary(report: dict[str, Any]) -> None:
    results = _list(report["results"], "report.results")
    _require(report["status"] in {"complete", "partial"}, "report status is invalid")
    checkpoint = _object(report["checkpoint"], "report.checkpoint")
    checkpoint_fields = {"accepted", "deferred", "failed", "remaining_row_ids"}
    _keys(checkpoint, checkpoint_fields, checkpoint_fields, "report.checkpoint")
    for status in ("accepted", "deferred", "failed"):
        count = _bounded_int(checkpoint[status], f"report.checkpoint.{status}", 0, MAX_ROWS)
        _require(count == sum(item.get("status") == status for item in results), "checkpoint count is inconsistent")
    remaining = [_opaque(item, "report.checkpoint.remaining_row_ids[]") for item in _list(checkpoint["remaining_row_ids"], "remaining_row_ids")]
    expected_remaining = [item.get("row_id") for item in results if item.get("status") != "accepted"]
    _require(remaining == expected_remaining, "checkpoint remaining rows are inconsistent")
    metrics = _object(report["metrics"], "report.metrics")
    metric_fields = {"latency_ms", "input_tokens", "output_tokens", "cost_usd", "cost_measurement"}
    _keys(metrics, metric_fields, metric_fields, "report.metrics")
    _optional_metric(metrics["latency_ms"], "report.metrics.latency_ms")
    _optional_integer(metrics["input_tokens"], "report.metrics.input_tokens")
    _optional_integer(metrics["output_tokens"], "report.metrics.output_tokens")
    _optional_metric(metrics["cost_usd"], "report.metrics.cost_usd")
    expected_cost_state = "unknown" if metrics["cost_usd"] is None else "reported"
    _require(metrics["cost_measurement"] == expected_cost_state, "cost measurement state is inconsistent")


def validate_report(value: Any, request: ValidatedRequest | None = None) -> dict[str, Any]:
    """Validate essential consumer-facing report invariants."""
    report = _object(value, "report")
    required = {"schema", "request_id", "scope", "input_digest", "cache_key", "rubric", "model", "performance_window", "data_classification", "status", "results", "checkpoint", "metrics", "authority"}
    _keys(report, required, required, "report")
    if report["schema"] != REPORT_SCHEMA or report["authority"] != "non_mutating_recommendations_only":
        raise DecisionError("unknown or unsafe report contract")
    if not SHA256_RE.fullmatch(report["input_digest"]) or not SHA256_RE.fullmatch(report["cache_key"]):
        raise DecisionError("report digest is invalid")
    for item in _list(report["results"], "report.results"):
        if item.get("status") not in {"accepted", "deferred", "failed"}:
            raise DecisionError("report result status is invalid")
    _validate_report_summary(report)
    if request is not None:
        _validate_report_request(report, request)
    return report


def _ensure_private_root(root: Path) -> Path:
    if not root.is_absolute():
        raise DecisionError("storage path must be absolute")
    current = Path(root.anchor)
    for component in root.parts[1:]:
        current /= component
        created = False
        try:
            current.mkdir(mode=0o700)
            created = True
        except FileExistsError:
            pass
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise DecisionError("storage path contains a symlink or non-directory")
        if (current / ".git").exists() or (current / ".git").is_symlink():
            raise DecisionError("decision artifacts cannot be stored in Git")
        if created or current == root:
            os.chmod(current, 0o700)
    return root


def _atomic_create_or_replay(path: Path, payload: bytes, conflict: str) -> bool:
    """Publish complete bytes with one atomic link, or verify an identical replay."""
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".decision-", delete=False) as stream:
            temporary_name = stream.name
            os.chmod(temporary_name, 0o600)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary_name, path, follow_symlinks=False)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != payload:
                raise DecisionError(conflict)
            return True
        return False
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def store_report(root: str | Path, request: ValidatedRequest, report: dict[str, Any]) -> tuple[Path, bool]:
    """Atomically create or replay one scope-isolated report."""
    validate_report(report, request)
    scope = request.document["scope"]
    directory = _ensure_private_root(Path(root) / scope["project_id"] / scope["account_id"])
    payload = (json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
    identity_path = directory / f"request-{request.document['request_id']}.json"
    identity = {"input_digest": request.input_digest, "cache_key": request.cache_key}
    identity_payload = (canonical_json(identity) + "\n").encode()
    _atomic_create_or_replay(identity_path, identity_payload, "conflicting retry for request identity")
    report_path = directory / f"cache-{request.cache_key.split(':', 1)[1]}.json"
    replayed = _atomic_create_or_replay(report_path, payload, "conflicting cache replay")
    return report_path, replayed
