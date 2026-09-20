#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, fixture-backed discovery transport contracts.

Live provider clients deliberately live outside this module: this adapter accepts
only already-authorized pages and makes every unavailable capability explicit.
"""

from __future__ import annotations

from typing import Any

CAPABILITIES = frozenset({"search", "community", "thread", "rules"})


class CollectorError(ValueError):
    """Raised for an invalid read-only provider response."""


def capability_result(name: str, payload: Any) -> dict[str, Any]:
    """Normalize a provider capability result without invoking provider methods."""
    if name not in CAPABILITIES:
        raise CollectorError("unsupported collector capability")
    if not isinstance(payload, dict):
        raise CollectorError("collector result must be an object")
    status = payload.get("status", "available")
    if status not in {"available", "unavailable", "cooldown", "partial"}:
        raise CollectorError("collector status is invalid")
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise CollectorError("collector items must be an array")
    return {"capability": name, "status": status, "items": items, "next_cursor": payload.get("next_cursor")}
