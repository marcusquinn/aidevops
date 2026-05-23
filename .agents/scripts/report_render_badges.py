#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence badge helpers for report rendering."""

from __future__ import annotations

from typing import Any

BADGE_VERIFIED = "verified"
BADGE_PARTIAL = "partial"
BADGE_INFERRED = "inferred"
BADGE_MISSING = "missing"
BADGE_KEY = "evidence_badge"

ALLOWED_BADGES = (BADGE_VERIFIED, BADGE_PARTIAL, BADGE_INFERRED, BADGE_MISSING)
BADGE_LABELS = {
    BADGE_VERIFIED: "Verified",
    BADGE_PARTIAL: "Partial",
    BADGE_INFERRED: "Inferred",
    BADGE_MISSING: "Missing",
}


def badge_html(value: Any) -> str:
    key = str(value).strip().lower()
    if key not in ALLOWED_BADGES:
        raise ValueError(f"unknown evidence badge value: {value}")
    return f'<span class="badge badge-{key}"><span class="badge-prefix">Evidence:</span><span>{BADGE_LABELS[key]}</span></span>'
