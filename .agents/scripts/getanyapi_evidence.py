#!/usr/bin/env python3
"""Privacy-minimized local evidence for GetAnyAPI capability graduation."""

from __future__ import annotations

import json
import os
import stat
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

LEDGER_SCHEMA_VERSION = 1


class AnyAPIError(RuntimeError):
    """Customer-safe AnyAPI request failure."""

    def __init__(self, message: str, status: int = 0, body: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ledger_path() -> Path:
    root = Path(
        os.environ.get(
            "AIDEVOPS_WORKSPACE_DIR",
            str(Path.home() / ".aidevops" / ".agent-workspace"),
        )
    )
    return root / "observability" / "getanyapi-usage.jsonl"


def safe_native_path(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if value.startswith(("/", "~")) or ".." in Path(value).parts:
        raise AnyAPIError("native path must be a repository-relative agent or helper path")
    return value[:240]


def decimal_value(value: Any, field: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise AnyAPIError(f"AnyAPI returned an invalid {field}") from exc
    if result < 0:
        raise AnyAPIError(f"AnyAPI returned a negative {field}")
    return result


def append_evidence(event: dict[str, Any]) -> None:
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise AnyAPIError("usage evidence file must not be a symlink")
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    bounded = {
        "schema_version": LEDGER_SCHEMA_VERSION,
        "recorded_at": utc_now(),
        "sku": str(event.get("sku") or "")[:160],
        "category": str(event.get("category") or "")[:80],
        "outcome": str(event.get("outcome") or "unknown")[:40],
        "request_id": str(event.get("request_id") or "")[:160],
        "http_status": int(event.get("http_status") or 0),
        "error_code": str(event.get("error_code") or "")[:120],
        "quoted_max_usd": str(event.get("quoted_max_usd") or "0")[:40],
        "observed_cost_usd": str(event.get("observed_cost_usd") or "0")[:40],
        "charged_cost_usd": str(event.get("charged_cost_usd") or "0")[:40],
        "items": int(event.get("items") or 0),
        "replayed": bool(event.get("replayed") or False),
        "native_status": str(event.get("native_status") or "unknown")[:40],
        "native_path": safe_native_path(str(event.get("native_path") or "")),
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, (json.dumps(bounded, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(descriptor)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def read_evidence() -> list[dict[str, Any]]:
    path = ledger_path()
    if not path.exists():
        return []
    if path.is_symlink() or not path.is_file():
        raise AnyAPIError("usage evidence file must be a regular, non-symlink file")
    events: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("schema_version") == LEDGER_SCHEMA_VERSION:
            events.append(value)
    return events


def build_study(events: list[dict[str, Any]], sku_filter: str = "") -> dict[str, Any]:
    filtered = [event for event in events if not sku_filter or event.get("sku") == sku_filter]
    latest_by_request: dict[str, dict[str, Any]] = {}
    unkeyed: list[dict[str, Any]] = []
    for event in filtered:
        request_id = str(event.get("request_id") or "")
        if request_id:
            latest_by_request[request_id] = event
        else:
            unkeyed.append(event)
    terminal = list(latest_by_request.values()) + unkeyed
    grouped: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "successful_uses": 0,
            "charged_usd": Decimal("0"),
            "items": 0,
            "attempts": 0,
            "native_statuses": set(),
            "native_paths": set(),
        }
    )
    for event in terminal:
        sku = str(event.get("sku") or "unknown")
        row = grouped[sku]
        row["attempts"] += 1
        row["native_statuses"].add(str(event.get("native_status") or "unknown"))
        if event.get("native_path"):
            row["native_paths"].add(str(event["native_path"]))
        row["charged_usd"] += decimal_value(
            event.get("charged_cost_usd", 0), "ledger cost"
        )
        if event.get("outcome") == "success":
            row["successful_uses"] += 1
            row["items"] += int(event.get("items") or 0)
    candidates = []
    for sku, row in grouped.items():
        candidates.append(
            {
                "sku": sku,
                "attempts": row["attempts"],
                "successful_uses": row["successful_uses"],
                "charged_usd": str(row["charged_usd"]),
                "items": row["items"],
                "native_statuses": sorted(row["native_statuses"]),
                "native_paths": sorted(row["native_paths"]),
                "next_decision": "assess native aidevops graduation with volume, terms, quality, and maintenance evidence",
            }
        )
    candidates.sort(
        key=lambda row: (Decimal(row["charged_usd"]), row["successful_uses"], row["items"]),
        reverse=True,
    )
    total_charged = sum((Decimal(row["charged_usd"]) for row in candidates), Decimal("0"))
    return {
        "evidence_events": len(filtered),
        "terminal_uses": len(terminal),
        "successful_uses": sum(row["successful_uses"] for row in candidates),
        "charged_usd": str(total_charged),
        "candidates": candidates,
        "interpretation": "ranked evidence only; no automatic build threshold",
    }
