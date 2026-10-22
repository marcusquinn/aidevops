#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared response, failure, and fixture contract for social knowledge readers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_social_fixture import FixtureSequence


@dataclass(frozen=True)
class ReaderContract:
    """Provider-specific messages and limits for one guarded reader."""

    adapter_error: type[Exception]
    unavailable_error: type[Exception]
    max_response_bytes: int
    safe_failures: tuple[str, ...]
    unavailable_message: str
    oversize_message: str
    invalid_json_message: str
    root_message: str
    expectation_message: str
    checkpoint_message: str
    response_message: str

    def decode_output(self, output: str) -> dict[str, Any]:
        """Decode one bounded JSON object emitted by the read child."""
        if len(output.encode("utf-8")) > self.max_response_bytes:
            raise self.adapter_error(self.oversize_message)
        try:
            payload = json.loads(output)
        except json.JSONDecodeError as error:
            raise self.adapter_error(self.invalid_json_message) from error
        if not isinstance(payload, dict):
            raise self.adapter_error(self.root_message)
        return payload

    def provider_failure(self, stderr: str) -> Exception:
        """Map child stderr to an allowlisted message, never raw output."""
        for message in self.safe_failures:
            if f"ERROR: {message}" in stderr:
                return self.unavailable_error(message)
        return self.unavailable_error(self.unavailable_message)

    def fixture_page(self, entry: dict[str, Any], request: Any) -> dict[str, Any]:
        """Return one fixture response after checking the resume expectation."""
        expectation = entry.get("expect_request", {})
        if not isinstance(expectation, dict):
            raise self.adapter_error(self.expectation_message)
        actual = request.payload()
        if any(actual.get(key) != value for key, value in expectation.items()):
            raise self.adapter_error(self.checkpoint_message)
        response = entry.get("response", entry)
        if not isinstance(response, dict):
            raise self.adapter_error(self.response_message)
        return response


class FixtureReader:
    """Deterministic provider substitute driven by a private fixture file."""

    def __init__(self, path: Path, provider: str, contract: ReaderContract) -> None:
        self.contract = contract
        self.fixture = FixtureSequence(path, provider, contract.adapter_error)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: Any) -> dict[str, Any]:
        return self.contract.fixture_page(self.fixture.next_page(), request)
