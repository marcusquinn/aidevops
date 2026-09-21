#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Strict, provider-neutral validation for bounded public-engagement grants."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping

MODES = ("disabled", "exact-draft", "policy")
ALLOWED_ACTIONS = frozenset({"post", "reply"})
MAX_RULE_AGE_SECONDS = 7 * 24 * 60 * 60


class PolicyError(ValueError):
    """Raised when policy input cannot confer publishing authority."""


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _identifier(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise PolicyError(f"{field} is invalid")
    if not all(character.isalnum() or character in "._:-" for character in value):
        raise PolicyError(f"{field} is invalid")
    return value


def _strings(value: object, field: str, *, maximum: int = 100) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or len(value) > maximum:
        raise PolicyError(f"{field} must be a non-empty bounded list")
    result = tuple(sorted({_identifier(item, field) for item in value}))
    if "*" in result:
        raise PolicyError(f"{field} cannot contain wildcards")
    return result


def _positive(value: object, field: str, maximum: int = 10000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= maximum:
        raise PolicyError(f"{field} must be a positive bounded integer")
    return value


@dataclass(frozen=True)
class Grant:
    grant_id: str
    revision: int
    owner_id: str
    project_id: str
    corpus_id: str
    connection_id: str
    account_id: str
    communities: tuple[str, ...]
    actions: tuple[str, ...]
    not_before: int
    expires_at: int
    window_seconds: int
    account_cap: int
    community_cap: int
    thread_cooldown_seconds: int
    thread_turn_cap: int
    disclosure: str
    rules_max_age_seconds: int
    enabled: bool
    policy_hash: str


def parse_grant(document: Mapping[str, Any]) -> Grant:
    """Validate one exact grant document and return its hash-bound form."""
    expected = {
        "grant_id", "revision", "owner_id", "project_id", "corpus_id",
        "provider", "connection_id", "account_id", "communities", "actions",
        "not_before", "expires_at", "window_seconds", "account_cap",
        "community_cap", "thread_cooldown_seconds", "thread_turn_cap",
        "disclosure", "rules_max_age_seconds", "enabled",
    }
    if set(document) != expected:
        raise PolicyError("grant fields do not match the versioned policy contract")
    if document.get("provider") != "reddit":
        raise PolicyError("delegated engagement supports only Reddit")
    actions = _strings(document.get("actions"), "actions", maximum=2)
    if not set(actions).issubset(ALLOWED_ACTIONS):
        raise PolicyError("grant contains a prohibited action")
    revision = _positive(document.get("revision"), "revision")
    not_before = document.get("not_before")
    expires_at = document.get("expires_at")
    if any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in (not_before, expires_at)):
        raise PolicyError("grant validity window is invalid")
    if expires_at <= not_before:
        raise PolicyError("grant expiry must follow its start")
    disclosure = document.get("disclosure")
    if not isinstance(disclosure, str) or not disclosure.strip() or len(disclosure) > 256:
        raise PolicyError("grant requires a bounded disclosure marker")
    enabled = document.get("enabled")
    if not isinstance(enabled, bool):
        raise PolicyError("enabled must be boolean")
    rules_age = _positive(document.get("rules_max_age_seconds"), "rules_max_age_seconds", MAX_RULE_AGE_SECONDS)
    normalized = dict(document)
    normalized["communities"] = list(_strings(document.get("communities"), "communities"))
    normalized["actions"] = list(actions)
    return Grant(
        _identifier(document.get("grant_id"), "grant_id"), revision,
        _identifier(document.get("owner_id"), "owner_id"),
        _identifier(document.get("project_id"), "project_id"),
        _identifier(document.get("corpus_id"), "corpus_id"),
        _identifier(document.get("connection_id"), "connection_id"),
        _identifier(document.get("account_id"), "account_id"),
        tuple(normalized["communities"]), tuple(normalized["actions"]),
        not_before, expires_at,
        _positive(document.get("window_seconds"), "window_seconds", 31 * 24 * 60 * 60),
        _positive(document.get("account_cap"), "account_cap"),
        _positive(document.get("community_cap"), "community_cap"),
        _positive(document.get("thread_cooldown_seconds"), "thread_cooldown_seconds", 31 * 24 * 60 * 60),
        _positive(document.get("thread_turn_cap"), "thread_turn_cap"),
        disclosure.strip(), rules_age, enabled, digest(normalized),
    )


def preview(document: Mapping[str, Any], current_time: int) -> dict[str, Any]:
    mode = document.get("mode", "disabled")
    if mode not in MODES:
        raise PolicyError("unsupported engagement mode")
    grants = document.get("grants", [])
    if not isinstance(grants, list):
        raise PolicyError("grants must be a list")
    parsed = [parse_grant(item) for item in grants]
    active = [grant for grant in parsed if grant.enabled and grant.not_before <= current_time < grant.expires_at]
    return {
        "schema": "aidevops.public-engagement-policy/v1",
        "mode": mode,
        "default_sends": 0,
        "grant_count": len(parsed),
        "active_grant_count": len(active) if mode == "policy" else 0,
        "grant_hashes": [grant.policy_hash for grant in parsed],
    }
