#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused staged-scan transport and replay tests."""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from prospecting_scan import ScanError, scan  # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "scan.json"


class ProspectingScanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.document = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_stages_titles_then_preserves_budget_gap_and_rules(self) -> None:
        result = scan(self.document)
        self.assertEqual(1, len(result["leads"]))
        self.assertEqual("comment-1", result["leads"][0]["object_id"])
        self.assertEqual("stale", result["leads"][0]["community_policy"]["status"])
        self.assertEqual("thread-2", result["unread"][0]["object_id"])
        self.assertEqual("budget_exhausted", result["unread"][0]["reason"])
        self.assertEqual("prohibited", result["leads"][0]["external_action"])

    def test_replay_is_deterministic_and_dedupes_candidates(self) -> None:
        duplicate = copy.deepcopy(self.document)
        duplicate["capabilities"]["community"]["items"] = duplicate["capabilities"]["search"]["items"][:1]
        self.assertEqual(scan(duplicate), scan(duplicate))
        self.assertEqual(1, len(scan(duplicate)["leads"]))

    def test_missing_buyer_reason_is_rejected(self) -> None:
        malformed = copy.deepcopy(self.document)
        del malformed["capabilities"]["search"]["items"][0]["comments"][0]["decision"]["reason"]
        with self.assertRaises(ScanError):
            scan(malformed)


if __name__ == "__main__":
    unittest.main()
