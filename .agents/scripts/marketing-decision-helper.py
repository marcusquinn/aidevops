#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate or run bounded offline marketing decision batches."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

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


def canonical_json(value: Any) -> str:
    """Serialize JSON deterministically and reject non-finite values."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value: Any) -> str:
    """Return a canonical content digest."""
    return "sha256:" + hashlib.sha256(canonical_json(value).encode()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DecisionError(message)


def object_value(value: Any, field: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{field} must be an object")
    return value


def list_value(value: Any, field: str) -> list[Any]:
    require(isinstance(value, list), f"{field} must be an array")
    return value


def opaque(value: Any, field: str) -> str:
    require(isinstance(value, str) and bool(OPAQUE_RE.fullmatch(value)), f"{field} must be an opaque identifier")
    return value


def timestamp(value: Any, field: str) -> str:
    require(isinstance(value, str) and value.endswith("Z"), f"{field} must be a UTC timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise DecisionError(f"{field} must be a UTC timestamp") from error
    return value


def number(value: Any, field: str, minimum: float = 0) -> float | int:
    require(not isinstance(value, bool) and isinstance(value, (int, float)), f"{field} must be a number")
    require(math.isfinite(value) and value >= minimum, f"{field} is outside the supported range")
    return value


def bounded_int(value: Any, field: str, minimum: int, maximum: int) -> int:
    require(not isinstance(value, bool) and isinstance(value, int), f"{field} must be an integer")
    require(minimum <= value <= maximum, f"{field} is outside the supported range")
    return value


def keys(value: dict[str, Any], required: set[str], allowed: set[str], field: str) -> None:
    require(required <= set(value), f"{field} is missing required fields")
    require(not set(value) - allowed, f"{field} contains unknown fields")


def optional_metric(value: Any, field: str) -> float | int | None:
    return None if value is None else number(value, field)


def optional_integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    require(
        not isinstance(value, bool) and isinstance(value, int) and value >= 0,
        f"{field} must be a non-negative integer or null",
    )
    return value


def safe_summary(value: Any) -> str | None:
    if value is None:
        return None
    require(isinstance(value, str), "action proposal summary is unsafe")
    require(len(value) <= 500, "action proposal summary is unsafe")
    require("://" not in value and "$(" not in value, "action proposal summary is unsafe")
    return value


def load_json(path: str | Path, maximum: int = MAX_INPUT_BYTES) -> Any:
    """Load one bounded JSON document."""
    with Path(path).open("rb") as stream:
        raw = stream.read(maximum + 1)
    require(len(raw) <= maximum, "input exceeds byte budget")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise DecisionError("input is not valid JSON") from error


def validate_scope(scope: Any) -> dict[str, str]:
    scope = object_value(scope, "scope")
    keys(scope, {"project_id", "account_id"}, {"project_id", "account_id", "site_id"}, "scope")
    return {key: opaque(value, f"scope.{key}") for key, value in scope.items()}


def validate_versioned(value: Any, field: str, extra: set[str] | None = None) -> dict[str, str]:
    value = object_value(value, field)
    allowed = {"id", "version"} | (extra or set())
    keys(value, {"id", "version"}, allowed, field)
    return {key: opaque(item, f"{field}.{key}") for key, item in value.items()}


def validate_limits(value: Any) -> dict[str, Any]:
    value = object_value(value, "limits")
    required = {"max_rows", "max_candidates_per_row", "max_concurrency", "budget"}
    keys(value, required, required, "limits")
    budget = object_value(value["budget"], "limits.budget")
    budget_fields = {"max_latency_ms", "max_input_tokens", "max_output_tokens", "max_cost_usd"}
    keys(budget, budget_fields, budget_fields, "limits.budget")
    normalized_budget = {
        "max_latency_ms": optional_metric(budget["max_latency_ms"], "limits.budget.max_latency_ms"),
        "max_input_tokens": optional_integer(budget["max_input_tokens"], "limits.budget.max_input_tokens"),
        "max_output_tokens": optional_integer(budget["max_output_tokens"], "limits.budget.max_output_tokens"),
        "max_cost_usd": optional_metric(budget["max_cost_usd"], "limits.budget.max_cost_usd"),
    }
    return {
        "max_rows": bounded_int(value["max_rows"], "limits.max_rows", 1, MAX_ROWS),
        "max_candidates_per_row": bounded_int(
            value["max_candidates_per_row"], "limits.max_candidates_per_row", 1, MAX_CANDIDATES
        ),
        "max_concurrency": bounded_int(value["max_concurrency"], "limits.max_concurrency", 1, MAX_CONCURRENCY),
        "budget": normalized_budget,
    }


def ensure_private_root(root: Path) -> Path:
    require(root.is_absolute(), "storage path must be absolute")
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
        require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode), "storage path contains a symlink or non-directory")
        require(not (current / ".git").exists() and not (current / ".git").is_symlink(), "decision artifacts cannot be stored in Git")
        if created or current == root:
            os.chmod(current, 0o700)
    return root


def atomic_create_or_replay(path: Path, payload: bytes, conflict: str) -> bool:
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
            require(not path.is_symlink() and path.read_bytes() == payload, conflict)
            return True
        return False
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marketing_decisions as contract


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="Validate one decision input")
    validate.add_argument("--input", required=True)
    run = commands.add_parser("run", help="Run with explicitly supplied offline decisions")
    run.add_argument("--input", required=True)
    run.add_argument("--decisions", required=True)
    run.add_argument("--dry-run", action="store_true", required=True)
    run.add_argument("--store", help="Explicit absolute private artifact directory")
    return parser


def execute(args: argparse.Namespace) -> dict[str, object]:
    request = contract.validate_input(contract.load_json(args.input))
    if args.command == "validate":
        return {
            "status": "valid",
            "schema": contract.INPUT_SCHEMA,
            "input_digest": request.input_digest,
            "cache_key": request.cache_key,
            "rows": sum(len(batch["rows"]) for batch in request.document["batches"]),
        }
    supplied = contract.validate_supplied(contract.load_json(args.decisions), request)
    report = contract.run(request, supplied)
    contract.validate_report(report, request)
    if args.store:
        contract.store_report(Path(args.store), request, report)
    return report


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        print(json.dumps(execute(args), sort_keys=True, allow_nan=False))
        return 0
    except (OSError, TypeError, contract.DecisionError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_decisions_or_storage"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
