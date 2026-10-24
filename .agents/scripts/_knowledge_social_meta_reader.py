#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for Meta product data."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_collect_cli import guarded_reader_environment
from _knowledge_social_meta import (
    MetaAdapterError,
    MetaProviderUnavailableError,
    PageRequest,
    account_id,
    product_spec,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_reader_contract import FixtureReader, ReaderContract
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Meta OAuth profile access token is missing",
    "Meta OAuth profile name is invalid",
    "Meta product is unsupported",
)


class MetaReader(Protocol):
    """Minimal GET-only provider surface used by collection."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


CONTRACT = ReaderContract(
    adapter_error=MetaAdapterError,
    unavailable_error=MetaProviderUnavailableError,
    max_response_bytes=MAX_RESPONSE_BYTES,
    safe_failures=SAFE_PROVIDER_FAILURES,
    unavailable_message="Meta read provider is unavailable",
    oversize_message="Meta read response exceeds the safety limit",
    invalid_json_message="Meta read provider returned no valid JSON",
    root_message="Meta read response root must be an object",
    expectation_message="Meta fixture request expectation must be an object",
    checkpoint_message="Meta request did not resume at the expected checkpoint",
    response_message="Meta fixture page response must be an object",
)


META_OAUTH_POLICY = GuardedOAuthPolicy(
    "Meta",
    "META",
    "META_READ_LOG",
    READ_TIMEOUT_SECONDS,
    CONTRACT.decode_output,
    CONTRACT.provider_failure,
    MetaProviderUnavailableError,
)


class GuardedMetaOAuth(GuardedOAuthReader):
    """Execute only one product identity and its allowlisted Graph GETs."""

    def __init__(self, helper: Path, profile: str, product: str) -> None:
        product_spec(product)
        self.product = product
        super().__init__(helper, profile, META_OAUTH_POLICY)

    def _environment(self) -> dict[str, str]:
        token_name = f"META_{self.profile.upper()}_{self.product.upper()}_ACCESS_TOKEN"
        return guarded_reader_environment(token_name, ("META_READ_LOG",))

    def identity(self, expected_id: str) -> dict[str, Any]:
        return self.process.run(
            {"action": "identity", "product": self.product, "account_id": expected_id}
        )


class FixtureMeta(FixtureReader):
    """Deterministic OAuth substitute for product pagination and failures."""

    def __init__(self, path: Path, product: str) -> None:
        self.product = product
        super().__init__(path, f"Meta {product}", CONTRACT)

    def page(self, request: PageRequest) -> dict[str, Any]:
        if request.product != self.product:
            raise MetaAdapterError("Meta fixture product does not match the request")
        return super().page(request)


def verified_identity(
    payload: dict[str, Any], expected_id: str, product: str
) -> dict[str, Any]:
    """Validate product identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise MetaAdapterError(f"{product} account verification returned no account")
    remote_id = account_id(data.get("id"), "account ID")
    if data.get("product") != product or remote_id != expected_id:
        raise MetaAdapterError(
            f"selected {product} account does not match the configured connection"
        )
    account = {"id": remote_id, "product": product}
    for field in ("username", "name", "category", "is_verified"):
        value = data.get(field)
        if isinstance(value, (str, bool)):
            account[field] = value
    return account
