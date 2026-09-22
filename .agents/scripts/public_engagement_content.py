#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed public-engagement draft validation and stable intent IDs."""

from __future__ import annotations

import hashlib
from typing import Any, Mapping


class ContentError(ValueError):
    """Raised when untrusted source evidence cannot become an engagement draft."""


PROHIBITED_ACTIONS = frozenset({"dm", "vote", "like", "follow", "moderate"})
SENSITIVE_TERMS = frozenset({"medical", "legal", "financial", "political"})


def stable_intent_id(candidate: Mapping[str, Any]) -> str:
    """Return a deterministic source/action ID; retries cannot create a new send."""
    values = (candidate.get("source_id"), candidate.get("account_id"), candidate.get("action"))
    if not all(isinstance(value, str) and value for value in values):
        raise ContentError("source_id, account_id, and action are required")
    return "eng_" + hashlib.sha256("\x1f".join(values).encode()).hexdigest()[:32]


def draft(candidate: Mapping[str, Any], *, disclosure: str) -> dict[str, Any]:
    """Validate evidence and return a reviewable, never-published draft."""
    action = candidate.get("action")
    if action not in {"post", "reply"} or action in PROHIBITED_ACTIONS:
        raise ContentError("only bounded public posts and replies are supported")
    required = ("source_id", "thread_id", "community", "account_id", "question", "answer", "source_url")
    if any(not isinstance(candidate.get(key), str) or not candidate[key].strip() for key in required):
        raise ContentError("candidate is missing observed relevance or evidence")
    if not candidate.get("community_permission"):
        raise ContentError("community permission is unknown; route to review")
    if candidate.get("opted_out") or candidate.get("suppressed"):
        raise ContentError("candidate is suppressed")
    text = candidate["answer"].strip()
    if not disclosure.strip() or disclosure not in text:
        raise ContentError("draft requires the authorized disclosure")
    if any(term in text.lower() for term in SENSITIVE_TERMS):
        raise ContentError("sensitive advice requires human review")
    return {
        "intent_id": stable_intent_id(candidate), "state": "draft",
        "action": action, "thread_id": candidate["thread_id"],
        "community": candidate["community"], "account_id": candidate["account_id"],
        "source_id": candidate["source_id"], "source_url": candidate["source_url"],
        "body": text, "disclosure": disclosure,
        "authority": "review_required", "published": False,
    }
