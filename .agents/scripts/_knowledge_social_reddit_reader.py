#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only Reddit adapter."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_collect_cli import GuardedReaderProcess
from _knowledge_social_reader_contract import FixtureReader, ReaderContract
from _knowledge_social_reddit import (
    PageRequest,
    RedditAdapterError,
    RedditProviderUnavailableError,
)
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "PRAW is unavailable; install it outside the agent session",
    "PRAW major version 8 is required",
    "PRAW listing generator metadata is unavailable",
    "PRAW listing generator is incompatible",
    "Reddit auth profile credentials are incomplete",
    "Reddit auth profile name is invalid",
)


class RedditReader(Protocol):
    """Minimal read-only provider surface used by Reddit collection."""

    def identity(self) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


CONTRACT = ReaderContract(
    adapter_error=RedditAdapterError,
    unavailable_error=RedditProviderUnavailableError,
    max_response_bytes=MAX_RESPONSE_BYTES,
    safe_failures=SAFE_PROVIDER_FAILURES,
    unavailable_message="Reddit read provider is unavailable",
    oversize_message="Reddit read response exceeds the safety limit",
    invalid_json_message="Reddit read provider returned no valid JSON",
    root_message="Reddit read response root must be an object",
    expectation_message="Reddit fixture request expectation must be an object",
    checkpoint_message="Reddit request did not resume at the expected checkpoint",
    response_message="Reddit fixture page response must be an object",
)
# Module-level alias retained for the existing sanitized-failure test import.
_provider_failure = CONTRACT.provider_failure


class GuardedPraw:
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        if helper.is_symlink() or not helper.is_file():
            raise RedditProviderUnavailableError("Reddit read provider is unavailable")
        self.profile = profile
        self.process = GuardedReaderProcess(
            helper=helper,
            profile=profile,
            environment=self._environment,
            timeout_seconds=READ_TIMEOUT_SECONDS,
            decode_output=CONTRACT.decode_output,
            provider_failure=CONTRACT.provider_failure,
            unavailable_error=RedditProviderUnavailableError,
            provider_name="Reddit",
        )

    def _environment(self) -> dict[str, str]:
        profile_prefix = f"REDDIT_{self.profile.upper()}_"
        credential_names = {
            f"{profile_prefix}{field}"
            for field in (
                "CLIENT_ID",
                "CLIENT_SECRET",
                "PASSWORD",
                "USER_AGENT",
                "USERNAME",
            )
        }
        inherited = {
            "HOME",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "LANG",
            "LC_ALL",
            "NO_PROXY",
            "PATH",
            "REQUESTS_CA_BUNDLE",
            "SSL_CERT_FILE",
            "TMPDIR",
            "https_proxy",
            "http_proxy",
            "no_proxy",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in inherited or key in credential_names
        }
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            for key in (
                "AIDEVOPS_TEST_MODE",
                "PYTHONPATH",
                "REDDIT_READ_LOG",
                "REDDIT_READ_MODE",
            ):
                if key in os.environ:
                    environment[key] = os.environ[key]
        return environment

    def identity(self) -> dict[str, Any]:
        return self.process.run({"action": "identity"})

    def page(self, request: PageRequest) -> dict[str, Any]:
        return self.process.run(request.payload())


class FixtureReddit(FixtureReader):
    """Deterministic PRAW substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, "Reddit", CONTRACT)

    def identity(self) -> dict[str, Any]:  # type: ignore[override]
        # The Reddit reader protocol takes no expected ID; keep that surface.
        return self.fixture.identity()


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate PRAW identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise RedditAdapterError("Reddit account verification returned no account")
    remote_id = data.get("id")
    username = data.get("username")
    if not isinstance(remote_id, str) or not remote_id:
        raise RedditAdapterError("Reddit account verification returned no account ID")
    if username is not None and (not isinstance(username, str) or not username):
        raise RedditAdapterError("Reddit account name must be text")
    if remote_id != expected_id:
        raise RedditAdapterError(
            "selected Reddit account does not match the configured connection"
        )
    return data
