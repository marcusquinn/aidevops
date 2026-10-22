#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Hacker News."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_hacker_news import PageRequest
from _knowledge_social_hacker_news_contract import (
    HackerNewsReadProviderError,
    MAX_ITEM_RESPONSE_BYTES,
    MAX_USER_RESPONSE_BYTES,
    submitted_ids,
)
from _knowledge_social_hacker_news_identity import (
    HackerNewsAdapterError,
    HackerNewsProviderUnavailableError,
    selector_id,
    username,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_reader_contract import FixtureReader, ReaderContract
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = MAX_USER_RESPONSE_BYTES + MAX_ITEM_RESPONSE_BYTES + 256 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Hacker News profile must be the credential-free public profile",
    "Hacker News public username is invalid",
    "Hacker News public selector changed during collection",
)


class HackerNewsReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


CONTRACT = ReaderContract(
    adapter_error=HackerNewsAdapterError,
    unavailable_error=HackerNewsProviderUnavailableError,
    max_response_bytes=MAX_RESPONSE_BYTES,
    safe_failures=SAFE_PROVIDER_FAILURES,
    unavailable_message='Hacker News public read provider is unavailable',
    oversize_message='Hacker News read response exceeds the safety limit',
    invalid_json_message='Hacker News read provider returned no valid JSON',
    root_message='Hacker News read response root must be an object',
    expectation_message='Hacker News fixture request expectation must be an object',
    checkpoint_message='Hacker News request did not resume at the expected checkpoint',
    response_message='Hacker News fixture page response must be an object',
)


HACKER_NEWS_READER_POLICY = GuardedOAuthPolicy(
    "Hacker News",
    "HACKER_NEWS",
    "HACKER_NEWS_READ_LOG",
    READ_TIMEOUT_SECONDS,
    CONTRACT.decode_output,
    CONTRACT.provider_failure,
    HackerNewsProviderUnavailableError,
    (),
    "public",
)


class GuardedHackerNews(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        if profile != "public":
            raise HackerNewsProviderUnavailableError(
                "Hacker News profile must be the credential-free public profile"
            )
        super().__init__(helper, profile, HACKER_NEWS_READER_POLICY)


class FixtureHackerNews(FixtureReader):
    def __init__(self, path: Path) -> None:
        super().__init__(path, 'Hacker News', CONTRACT)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Verify only an exact public selector, never authenticated account identity."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise HackerNewsAdapterError(
            "Hacker News public selector response returned no observation"
        )
    selected = username(data.get("username"))
    if selected != username(expected_id) or data.get("id") != selector_id(selected):
        raise HackerNewsAdapterError(
            "Hacker News public username does not match the configured selector"
        )
    availability = data.get("availability")
    if availability not in {"public", "missing"}:
        raise HackerNewsAdapterError(
            "Hacker News public selector availability is invalid"
        )
    try:
        submitted = submitted_ids(data.get("submitted", []))
    except HackerNewsReadProviderError as error:
        raise HackerNewsAdapterError(str(error)) from error
    response_bytes = data.get("response_bytes", 0)
    if (
        isinstance(response_bytes, bool)
        or not isinstance(response_bytes, int)
        or response_bytes < 0
        or response_bytes > MAX_USER_RESPONSE_BYTES
    ):
        raise HackerNewsAdapterError(
            "Hacker News public selector byte count is invalid"
        )
    return {
        "id": selector_id(selected),
        "username": selected,
        "availability": availability,
        "submitted": list(submitted),
        "created": data.get("created"),
        "karma": data.get("karma"),
        "about": data.get("about"),
        "response_bytes": response_bytes,
        "identity_boundary": "public_mutable_username_selector",
    }
