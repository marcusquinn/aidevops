#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Provider-neutral planning for bounded public engagement; this module never posts."""

from __future__ import annotations

from typing import Any, Mapping

from public_engagement_content import ContentError, draft
from public_engagement_receipts import project


def plan(document: Mapping[str, Any]) -> dict[str, Any]:
    """Create bounded drafts from synthetic/observed candidates, deduplicating sources."""
    policy = document.get("policy", {})
    if policy.get("mode", "disabled") == "disabled":
        return {"state": "disabled", "drafts": [], "sends": 0}
    disclosure = policy.get("disclosure")
    if not isinstance(disclosure, str):
        return {"state": "review_required", "drafts": [], "sends": 0, "reason": "missing disclosure"}
    drafts, rejected, seen = [], [], set()
    for candidate in document.get("candidates", []):
        try:
            item = draft(candidate, disclosure=disclosure)
            if item["intent_id"] in seen:
                raise ContentError("duplicate source/action")
            seen.add(item["intent_id"])
            drafts.append(item)
        except (ContentError, AttributeError) as error:
            rejected.append({"source_id": candidate.get("source_id") if isinstance(candidate, dict) else None,
                             "reason": str(error)})
    return {"state": "draft_only", "drafts": drafts, "rejected": rejected, "sends": 0}


def receipt_outcome(receipt: Mapping[str, Any]) -> dict[str, Any]:
    """Expose receipt projection as the only local response outcome."""
    return project(receipt)
