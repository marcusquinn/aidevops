#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Broker error replies must not be confused with authenticated challenge failures."""

import importlib.util
import sys
import unittest
from pathlib import Path

CORE_PATH = Path(__file__).resolve().parents[1] / "source_access_core.py"
SPEC = importlib.util.spec_from_file_location("source_access_context_error_test", CORE_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"cannot load {CORE_PATH}")
CORE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CORE
SPEC.loader.exec_module(CORE)


class ContextErrorTests(unittest.TestCase):
    def test_error_reply_has_safe_distinct_message(self) -> None:
        query = {"nonce": "challenge", "session_id": "ses_test", "repo_root": "/repo"}
        with self.assertRaisesRegex(
            CORE.SourceAccessError, "source context unavailable: worktree owner/session not verified"
        ) as caught:
            CORE._validated_context_reply({"error": "private peer text"}, query, 123, 456)
        self.assertNotIn("private peer text", str(caught.exception))

    def test_invalid_challenge_still_reports_identity_failure(self) -> None:
        query = {"nonce": "challenge", "session_id": "ses_test", "repo_root": "/repo"}
        with self.assertRaisesRegex(CORE.SourceAccessError, "peer identity or challenge did not match"):
            CORE._validated_context_reply({}, query, 123, 456)


if __name__ == "__main__":
    unittest.main()
