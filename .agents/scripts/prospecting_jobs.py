#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Deterministic, local-only prospecting routine planning and receipts."""
from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from typing import Any


class RoutineError(ValueError):
    pass


TERMINAL = {"complete", "skipped", "budget", "partial", "error", "cancelled"}


def _text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RoutineError(f"{name} must be non-empty text")
    return value.strip()


def _integer(value: Any, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise RoutineError(f"{name} must be an integer >= {minimum}")
    return value


def now_epoch(value: int | None = None) -> int:
    return int(datetime.now(UTC).timestamp()) if value is None else _integer(value, "now")


def slot_id(project: str, job: str, cadence: str, now: int) -> str:
    """Return a stable slot ID; hourly and daily jobs never share a receipt."""
    bucket = now // (3600 if cadence == "hourly" else 86400)
    raw = f"routine-v1\0{project}\0{job}\0{cadence}\0{bucket}"
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


def _budget(job: dict[str, Any]) -> dict[str, int | float | None]:
    limits = job.get("budget", {})
    if not isinstance(limits, dict):
        raise RoutineError("job.budget must be an object")
    result: dict[str, int | float | None] = {}
    for key in ("requests", "rows", "tokens", "wall_seconds"):
        result[key] = _integer(limits.get(key, 0), f"budget.{key}")
    dollars = limits.get("dollars")
    if dollars is not None and (isinstance(dollars, bool) or not isinstance(dollars, (int, float)) or dollars < 0):
        raise RoutineError("budget.dollars must be a non-negative number")
    result["dollars"] = dollars
    return result


def plan(document: dict[str, Any], now: int | None = None) -> dict[str, Any]:
    """Validate disabled-by-default jobs and produce a non-mutating execution plan."""
    project = _text(document.get("project_id"), "project_id")
    jobs = document.get("jobs")
    if not isinstance(jobs, list):
        raise RoutineError("jobs must be an array")
    epoch = now_epoch(now)
    selected = []
    for item in jobs:
        if not isinstance(item, dict):
            raise RoutineError("job must be an object")
        name = _text(item.get("id"), "job.id")
        cadence = item.get("cadence", "manual")
        if cadence not in {"manual", "hourly", "daily"}:
            raise RoutineError("job.cadence must be manual, hourly, or daily")
        enabled = item.get("enabled", False)
        if not isinstance(enabled, bool):
            raise RoutineError("job.enabled must be boolean")
        selected.append({"id": name, "cadence": cadence, "enabled": enabled,
                         "slot_id": slot_id(project, name, cadence, epoch), "budget": _budget(item),
                         "reason": "scheduled" if enabled else "disabled"})
    return {"schema": "aidevops.prospecting-routines-plan/v1", "project_id": project,
            "now": epoch, "authority": "local_dry_run", "jobs": selected}


def reserve(receipts: dict[str, Any], planned: dict[str, Any]) -> dict[str, Any]:
    """Atomically-modelled reservation: replay returns the original receipt."""
    key = _text(planned.get("slot_id"), "slot_id")
    previous = receipts.get(key)
    if previous is not None:
        return previous
    if not planned.get("enabled"):
        receipt = {"slot_id": key, "status": "skipped", "reason": "disabled", "reserved": {}}
    else:
        receipt = {"slot_id": key, "status": "running", "reserved": planned["budget"],
                   "cost": {"actual": None, "estimated": None, "unknown": True}}
    receipts[key] = receipt
    return receipt


def finish(receipt: dict[str, Any], status: str, *, actual: float | None = None, estimated: float | None = None) -> dict[str, Any]:
    if status not in TERMINAL:
        raise RoutineError("invalid terminal status")
    if receipt.get("status") in TERMINAL:
        return receipt
    receipt["status"] = status
    receipt["cost"] = {"actual": actual, "estimated": estimated, "unknown": actual is None and estimated is None}
    return receipt
