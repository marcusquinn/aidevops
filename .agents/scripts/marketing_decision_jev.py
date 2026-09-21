#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded TypeSafe Jev transport for the shared marketing decision contract."""

from __future__ import annotations

import json
import math
import urllib.error
import urllib.request
from typing import Any

import marketing_decisions as contract

MODEL = "jev-1.13.0"
ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MAX_RESPONSE_BYTES = 65_536
TIMEOUT_SECONDS = 15


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


def _number(value: Any, field: str) -> float | int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise contract.DecisionError(f"{field} must be a finite number")
    return value


def _unit(value: Any, field: str) -> float | int:
    value = _number(value, field)
    if not 0 <= value <= 1:
        raise contract.DecisionError(f"{field} must be between zero and one")
    return value


def _questions(request: contract.ValidatedRequest) -> dict[str, dict[str, Any]]:
    questions: dict[str, dict[str, Any]] = {}
    for batch in request.document["batches"]:
        for row in batch["rows"]:
            if row["decision_kind"] == "multi_label":
                for candidate in row["candidates"]:
                    questions[f"{row['row_id']}:{candidate}"] = {
                        "type": "noul", "instructions": "Is this observed candidate applicable?",
                        "state": {"row_id": row["row_id"], "candidate": candidate},
                    }
            else:
                questions[row["row_id"]] = {
                    "type": row["decision_kind"], "instructions": "Return only a bounded decision over observed candidates.",
                    "state": {"row_id": row["row_id"], "candidates": row["candidates"]},
                }
    return questions


def build_payload(request: contract.ValidatedRequest) -> dict[str, Any]:
    """Build a minimal fixed-endpoint payload from already validated identifiers."""
    return {"model": MODEL, "state": {"rubric": request.document["rubric"], "rows": request.document["batches"]}, "questions": _questions(request)}


def fetch(payload: dict[str, Any], key: str) -> dict[str, Any]:
    request = urllib.request.Request(ENDPOINT, data=json.dumps(payload).encode(), method="POST", headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise contract.DecisionError("provider response exceeds byte bound")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise contract.DecisionError("provider response is not JSON") from error


def _usage(answer: dict[str, Any]) -> dict[str, Any]:
    usage = answer.get("usage", {})
    if not isinstance(usage, dict) or set(usage) - {"latency_ms", "input_tokens", "output_tokens", "cost_usd"}:
        raise contract.DecisionError("provider usage is invalid")
    return {key: usage.get(key) for key in ("latency_ms", "input_tokens", "output_tokens", "cost_usd")}


def _calibration(answer: dict[str, Any]) -> dict[str, Any]:
    value = answer.get("calibration", {"provenance": "unknown", "reference": None})
    if not isinstance(value, dict) or set(value) != {"provenance", "reference"} or value["provenance"] not in contract.CONFIDENCE_PROVENANCE:
        raise contract.DecisionError("provider confidence provenance is invalid")
    return value


def supplied_from_response(response: Any, request: contract.ValidatedRequest) -> dict[str, Any]:
    """Translate only typed answers; malformed and drifted responses fail closed."""
    if not isinstance(response, dict) or response.get("model") != MODEL or not isinstance(response.get("answers"), dict):
        raise contract.DecisionError("provider model or answer envelope drifted")
    answers = response["answers"]
    questions = _questions(request)
    if set(answers) != set(questions):
        raise contract.DecisionError("provider answers do not match request")
    decisions = []
    for batch in request.document["batches"]:
        for row in batch["rows"]:
            if row["decision_kind"] == "multi_label":
                selected = []
                confidences = []
                usage = {"latency_ms": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0}
                for candidate in row["candidates"]:
                    answer = answers[f"{row['row_id']}:{candidate}"]
                    if not isinstance(answer, dict) or answer.get("type") != "noul":
                        raise contract.DecisionError("multi-label answer is invalid")
                    probability = _unit(answer.get("noul"), "provider noul")
                    if probability >= 0.5:
                        selected.append(candidate)
                    confidences.append(probability)
                    answer_usage = _usage(answer)
                    for key, value in answer_usage.items():
                        usage[key] = None if value is None or usage[key] is None else usage[key] + value
                decisions.append({"row_id": row["row_id"], "kind": "multi_label", "value": selected or None, "probability": None, "confidence": max(confidences), "calibration": {"provenance": "unknown", "reference": None}, "abstention_reason": None if selected else "no_label_above_threshold", "action_proposal": None, "usage": usage})
                continue
            answer = answers[row["row_id"]]
            if not isinstance(answer, dict) or answer.get("type") != row["decision_kind"]:
                raise contract.DecisionError("provider answer type is invalid")
            confidence = _unit(answer.get("confidence"), "provider confidence")
            if row["decision_kind"] == "choice":
                probabilities = answer.get("probabilities")
                if not isinstance(probabilities, dict) or set(probabilities) != set(row["candidates"]):
                    raise contract.DecisionError("choice probabilities are invalid")
                probabilities = {key: _unit(value, "choice probability") for key, value in probabilities.items()}
                if not math.isclose(sum(probabilities.values()), 1, abs_tol=0.001) or answer.get("choice") not in probabilities or probabilities[answer["choice"]] != max(probabilities.values()):
                    raise contract.DecisionError("choice answer is inconsistent")
                value, probability = answer["choice"], probabilities[answer["choice"]]
            else:
                value, probability = _number(answer.get("score"), "provider score"), None
            decisions.append({"row_id": row["row_id"], "kind": row["decision_kind"], "value": value, "probability": probability, "confidence": confidence, "calibration": _calibration(answer), "abstention_reason": None, "action_proposal": None, "usage": _usage(answer)})
    return contract.validate_supplied({"schema": contract.DECISIONS_SCHEMA, "request_id": request.document["request_id"], "input_digest": request.input_digest, "decisions": decisions}, request)


def decide(request: contract.ValidatedRequest, key: str | None) -> dict[str, Any]:
    if not key:
        return {"status": "fallback_required", "reason": "missing_access", "fallback_ran": False}
    try:
        report = contract.run(request, supplied_from_response(fetch(build_payload(request), key), request))
        if report["status"] != "complete":
            return {"status": "fallback_required", "reason": "budget_or_unresolved", "report": report, "fallback_ran": False}
        return {"status": "complete", "report": report, "fallback_ran": False}
    except urllib.error.HTTPError as error:
        error.close()
        reason = "cooldown" if error.code == 429 else "provider_unavailable"
    except (OSError, ValueError, TypeError, contract.DecisionError):
        reason = "malformed_or_unavailable"
    return {"status": "fallback_required", "reason": reason, "fallback_ran": False}
