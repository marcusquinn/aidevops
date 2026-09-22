#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Project queue receipts without treating drafts, pending work, or unknown as sends."""

from __future__ import annotations

from typing import Any, Mapping


def project(receipt: Mapping[str, Any]) -> dict[str, Any]:
    """Return the local activity disposition implied by an immutable queue receipt."""
    state = receipt.get("state")
    if state == "succeeded" and receipt.get("provider_remote_id"):
        disposition, responded = "responded", True
    elif state == "unknown":
        disposition, responded = "unresolved", False
    elif state in {"queued", "approved", "claimed", "pending"}:
        disposition, responded = "pending", False
    else:
        disposition, responded = "not_sent", False
    return {"intent_id": receipt.get("operation_id"), "disposition": disposition,
            "responded": responded, "provider_remote_id": receipt.get("provider_remote_id")}
