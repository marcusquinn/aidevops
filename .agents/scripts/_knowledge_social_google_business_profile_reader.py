#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for Google Business Profile."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_google_business_profile import (
    GoogleBusinessProfileAdapterError,
    GoogleBusinessProfileProviderUnavailableError,
    PageRequest,
    resource_id,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_reader_contract import FixtureReader, ReaderContract
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Google Business Profile OAuth profile is incomplete",
    "Google Business Profile OAuth profile name is invalid",
    "selected Google identity or Business Profile hierarchy does not match the configured connection",
)


class GoogleBusinessProfileReader(Protocol):
    """Minimal read-only provider surface consumed by collection."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


CONTRACT = ReaderContract(
    adapter_error=GoogleBusinessProfileAdapterError,
    unavailable_error=GoogleBusinessProfileProviderUnavailableError,
    max_response_bytes=MAX_RESPONSE_BYTES,
    safe_failures=SAFE_PROVIDER_FAILURES,
    unavailable_message='Google Business Profile read provider is unavailable',
    oversize_message='Google Business Profile read response exceeds the safety limit',
    invalid_json_message='Google Business Profile read provider returned no valid JSON',
    root_message='Google Business Profile read response root must be an object',
    expectation_message='Google Business Profile fixture request expectation must be an object',
    checkpoint_message='Google Business Profile request did not resume at the expected checkpoint',
    response_message='Google Business Profile fixture response must be an object',
)


GBP_OAUTH_POLICY = GuardedOAuthPolicy(
    "Google Business Profile",
    "GOOGLE_BUSINESS_PROFILE",
    "GOOGLE_BUSINESS_PROFILE_READ_LOG",
    READ_TIMEOUT_SECONDS,
    CONTRACT.decode_output,
    CONTRACT.provider_failure,
    GoogleBusinessProfileProviderUnavailableError,
    credential_suffixes=(
        "ACCESS_TOKEN",
        "GOOGLE_SUBJECT",
        "ACCOUNT_ID",
        "ORGANIZATION_ID",
        "LOCATION_ID",
    ),
)


class GuardedGoogleBusinessProfileOAuth(GuardedOAuthReader):
    """Execute only identity and allowlisted GET reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, GBP_OAUTH_POLICY)


class FixtureGoogleBusinessProfile(FixtureReader):
    """Deterministic substitute for hierarchy, pagination, and failure fixtures."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, 'Google Business Profile', CONTRACT)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate Google, account, organization, and location fences."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile identity returned no hierarchy"
        )
    location_id = resource_id(data.get("id"), "location ID")
    account_id = resource_id(data.get("business_account_id"), "business account ID")
    organization_id = resource_id(
        data.get("organization_id"), "organization ID", optional=True
    )
    if data.get("google_identity_verified") is not True:
        raise GoogleBusinessProfileAdapterError("Google identity was not verified")
    if location_id != expected_id:
        raise GoogleBusinessProfileAdapterError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    title = data.get("title")
    if title is not None and (not isinstance(title, str) or not title):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile location title must be text"
        )
    return {
        "id": location_id,
        "business_account_id": account_id,
        "organization_id": organization_id,
        "title": title,
    }
