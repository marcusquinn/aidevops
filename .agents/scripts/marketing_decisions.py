#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Provider-neutral validation and offline marketing decision execution."""

from __future__ import annotations

import importlib.util
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

_SUPPORT_SPEC = importlib.util.spec_from_file_location(
    "_marketing_decision_helper",
    Path(__file__).with_name("marketing-decision-helper.py"),
)
assert _SUPPORT_SPEC is not None and _SUPPORT_SPEC.loader is not None
_support = importlib.util.module_from_spec(_SUPPORT_SPEC)
_SUPPORT_SPEC.loader.exec_module(_support)

INPUT_SCHEMA = _support.INPUT_SCHEMA
DECISIONS_SCHEMA = _support.DECISIONS_SCHEMA
REPORT_SCHEMA = _support.REPORT_SCHEMA
MAX_INPUT_BYTES = _support.MAX_INPUT_BYTES
MAX_ROWS = _support.MAX_ROWS
MAX_CANDIDATES = _support.MAX_CANDIDATES
MAX_CONCURRENCY = _support.MAX_CONCURRENCY
SHA256_RE = _support.SHA256_RE
DECISION_KINDS = _support.DECISION_KINDS
CLASSIFICATIONS = _support.CLASSIFICATIONS
CONFIDENCE_PROVENANCE = _support.CONFIDENCE_PROVENANCE
DecisionError = _support.DecisionError
canonical_json = _support.canonical_json
digest = _support.digest
load_json = _support.load_json
_object = _support.object_value
_list = _support.list_value
_opaque = _support.opaque
_timestamp = _support.timestamp
_number = _support.number
_bounded_int = _support.bounded_int
_keys = _support.keys
_optional_metric = _support.optional_metric
_optional_integer = _support.optional_integer
_safe_summary = _support.safe_summary
_require = _support.require
_validate_scope = _support.validate_scope
_validate_versioned = _support.validate_versioned
_validate_limits = _support.validate_limits
_ensure_private_root = _support.ensure_private_root
_atomic_create_or_replay = _support.atomic_create_or_replay


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


@dataclass
class _RunState:
    by_id: dict[str, dict[str, Any]]
    usage: dict[str, float | int | None]
    budget: dict[str, Any]
    cancel_after: str | None
    cancelled: bool = False
    budget_stopped: str | None = None


def _validate_row(value: Any, limits: dict[str, Any], seen: set[str], field: str) -> dict[str, Any]:
    row = _object(value, field)
    required = {"row_id", "source", "decision_kind", "candidates"}
    _keys(row, required, required, field)
    row_id = _opaque(row["row_id"], f"{field}.row_id")
    _require(row_id not in seen, "row IDs must be unique")
    seen.add(row_id)
    source = _object(row["source"], f"{field}.source")
    _keys(source, {"source_id", "span"}, {"source_id", "span"}, f"{field}.source")
    normalized_source = {
        "source_id": _opaque(source["source_id"], f"{field}.source.source_id"),
        "span": _opaque(source["span"], f"{field}.source.span"),
    }
    kind = row["decision_kind"]
    _require(kind in DECISION_KINDS, f"{field}.decision_kind is unsupported")
    candidates = _list(row["candidates"], f"{field}.candidates")
    _require(
        bool(candidates) and len(candidates) <= limits["max_candidates_per_row"],
        f"{field}.candidates exceeds bounds",
    )
    candidate_ids = [_opaque(item, f"{field}.candidates[]") for item in candidates]
    _require(len(candidate_ids) == len(set(candidate_ids)), f"{field}.candidates must be unique")
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
    _require(data["schema"] == INPUT_SCHEMA, "unknown input schema version")
    scope = _validate_scope(data["scope"])
    window = _object(data["performance_window"], "performance_window")
    _keys(window, {"start", "end"}, {"start", "end"}, "performance_window")
    normalized_window = {
        "start": _timestamp(window["start"], "performance_window.start"),
        "end": _timestamp(window["end"], "performance_window.end"),
    }
    _require(normalized_window["start"] < normalized_window["end"], "performance window must increase")
    classification = data["data_classification"]
    _require(classification in CLASSIFICATIONS, "unsupported data classification")
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
        _require(bool(rows), f"{field}.rows cannot be empty")
        batches.append({
            "batch_id": _opaque(batch["batch_id"], f"{field}.batch_id"),
            "domain": _opaque(batch["domain"], f"{field}.domain"),
            "rows": rows,
        })
    _require(bool(batches) and len(seen) <= limits["max_rows"], "request row count exceeds bounds")
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
    _require(
        supplied_digest is None
        or (bool(SHA256_RE.fullmatch(supplied_digest)) and supplied_digest == input_digest),
        "input_digest does not match normalized input",
    )
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
    _require(data["schema"] == DECISIONS_SCHEMA, "unknown supplied-decision schema version")
    _require(data["request_id"] == request.document["request_id"], "decision request_id does not match input")
    _require(data["input_digest"] == request.input_digest, "decision input_digest does not match input")
    rows = _list(data["decisions"], "decisions.decisions")
    normalized = []
    seen: set[str] = set()
    for index, raw in enumerate(rows):
        item = _object(raw, f"decisions[{index}]")
        row_id = _opaque(item.get("row_id"), f"decisions[{index}].row_id")
        _require(row_id not in seen, "supplied decision row IDs must be unique")
        seen.add(row_id)
        normalized.append(item)
    known = {row["row_id"] for batch in request.document["batches"] for row in batch["rows"]}
    _require(not seen - known, "supplied decisions contain unknown row IDs")
    cancelled = data.get("cancelled_after_row_id")
    _require(cancelled is None or cancelled in known, "cancelled_after_row_id is unknown")
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
    _require(
        action["kind"] == "recommendation" and action["non_mutating"] is True and set(ids) <= candidates,
        "action proposal exceeds recommendation authority",
    )
    summary = _safe_summary(action.get("summary"))
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


def _run_row(batch: dict[str, Any], row: dict[str, Any], state: _RunState) -> dict[str, Any]:
    base = {
        "batch_id": batch["batch_id"],
        "domain": batch["domain"],
        "row_id": row["row_id"],
        "source": row["source"],
    }
    raw = state.by_id.get(row["row_id"])
    stopped_reason = "cancelled" if state.cancelled else state.budget_stopped
    if stopped_reason is not None or raw is None:
        reason = stopped_reason or "missing_decision"
        result = {**base, "status": "deferred", "reason": reason, "decision": None}
    else:
        result, state.usage = _evaluated_result(base, raw, row, state.usage, state.budget)
        if result["reason"] in {"budget_exceeded", "budget_usage_unknown"}:
            state.budget_stopped = result["reason"]
    state.cancelled = state.cancelled or row["row_id"] == state.cancel_after
    return result


def run(request: ValidatedRequest, supplied: dict[str, Any]) -> dict[str, Any]:
    """Evaluate supplied decisions without network access or workflow mutation."""
    state = _RunState(
        by_id={item["row_id"]: item for item in supplied["decisions"]},
        usage={"latency_ms": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0},
        budget=request.document["limits"]["budget"],
        cancel_after=supplied["cancelled_after_row_id"],
    )
    results = [
        _run_row(batch, row, state)
        for batch in request.document["batches"]
        for row in batch["rows"]
    ]
    usage = state.usage
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
    expected_status = "complete" if all(item.get("status") == "accepted" for item in results) else "partial"
    _require(report["status"] == expected_status, "report status is inconsistent with results")
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
    _require(
        report["schema"] == REPORT_SCHEMA and report["authority"] == "non_mutating_recommendations_only",
        "unknown or unsafe report contract",
    )
    _require(
        bool(SHA256_RE.fullmatch(report["input_digest"])) and bool(SHA256_RE.fullmatch(report["cache_key"])),
        "report digest is invalid",
    )
    for item in _list(report["results"], "report.results"):
        _require(item.get("status") in {"accepted", "deferred", "failed"}, "report result status is invalid")
    _validate_report_summary(report)
    if request is not None:
        _validate_report_request(report, request)
    return report


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
