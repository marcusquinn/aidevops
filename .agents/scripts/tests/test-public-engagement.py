#!/usr/bin/env python3
"""Focused synthetic tests for public-engagement draft and receipt boundaries."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from public_engagement import plan, receipt_outcome

FIXTURE = Path(__file__).parent / "fixtures" / "public-engagement" / "scenarios.json"


class PublicEngagementTests(unittest.TestCase):
    def test_plan_is_draft_only_and_rejects_opt_out(self) -> None:
        result = plan(json.loads(FIXTURE.read_text(encoding="utf-8")))
        self.assertEqual(result["state"], "draft_only")
        self.assertEqual(result["sends"], 0)
        self.assertEqual(len(result["drafts"]), 1)
        self.assertEqual(result["rejected"][0]["reason"], "candidate is suppressed")

    def test_unknown_receipt_never_becomes_response(self) -> None:
        result = receipt_outcome({"operation_id": "eng_fixture", "state": "unknown"})
        self.assertEqual(result["disposition"], "unresolved")
        self.assertFalse(result["responded"])

    def test_provider_receipt_is_required_for_response(self) -> None:
        result = receipt_outcome({"operation_id": "eng_fixture", "state": "succeeded", "provider_remote_id": "t1_remote"})
        self.assertTrue(result["responded"])


if __name__ == "__main__":
    unittest.main()
