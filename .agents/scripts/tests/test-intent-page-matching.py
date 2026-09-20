#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused offline tests for deterministic intent-to-page matching."""

from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("intent_page_matching", SCRIPTS / "intent_page_matching.py")
matching = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise RuntimeError("intent page matcher module is unavailable")
SPEC.loader.exec_module(matching)


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


class IntentPageMatchingTests(unittest.TestCase):
    def setUp(self):
        self.pages = fixture("intent-pages.json")
        self.decisions = fixture("intent-decisions.json")

    def test_exact_match_and_gap_brief_preserve_evidence(self):
        report = matching.match(self.pages, self.decisions)
        self.assertEqual(report["results"][0]["status"], "matched")
        self.assertEqual(report["results"][0]["observed_ranking_url"], "/pricing")
        self.assertEqual(report["results"][1]["status"], "abstained")
        self.assertEqual(report["results"][1]["reason"], "candidate_recall_insufficient")
        self.assertEqual(report["briefs"][0]["uncertainty"], "small_sample")
        self.assertTrue(report["briefs"][0]["non_mutating"])

    def test_multiple_and_offer_mismatch_do_not_force_choice(self):
        decisions = copy.deepcopy(self.decisions)
        pages = copy.deepcopy(self.pages)
        duplicate = copy.deepcopy(pages["pages"][2])
        duplicate["page_id"] = "compare-alternate"
        duplicate["url"] = "/compare/alternate"
        pages["pages"].append(duplicate)
        decisions["queries"][0]["query"] = "SEO audit comparison"
        report = matching.match(pages, decisions)
        self.assertEqual(report["results"][0]["status"], "multiple")
        decisions["queries"][0]["query"] = "SEO audit pricing"
        decisions["queries"][0]["offer"] = "lifetime guarantee"
        report = matching.match(self.pages, decisions)
        self.assertEqual(report["results"][0]["status"], "abstained")
        self.assertEqual(report["results"][0]["reason"], "offer_mismatch")

    def test_none_and_duplicate_commercial_intents_are_abstained_and_deduped(self):
        decisions = copy.deepcopy(self.decisions)
        decisions["queries"].append({**decisions["queries"][1], "query_id": "gap-duplicate"})
        report = matching.match(self.pages, decisions)
        self.assertEqual(len(report["briefs"]), 1)
        self.assertEqual(report["briefs"][0]["query_ids"], ["gap", "gap-duplicate"])

    def test_partial_and_no_candidate_retrieval_are_distinguished(self):
        decisions = copy.deepcopy(self.decisions)
        decisions["queries"][0]["query"] = "SEO audit procurement enterprise"
        decisions["queries"][1]["query"] = "garden irrigation tools"
        report = matching.match(self.pages, decisions)
        self.assertEqual(report["results"][0]["reason"], "candidate_recall_insufficient")
        self.assertEqual(report["results"][1]["reason"], "no_candidate_retrieved")

    def test_unknown_rubric_and_bad_page_hash_fail_closed(self):
        pages = copy.deepcopy(self.pages)
        pages["rubric"]["version"] = "2"
        with self.assertRaises(matching.MatchError):
            matching.match(pages, self.decisions)
        pages = copy.deepcopy(self.pages)
        pages["pages"][0]["page_hash"] = "wrong"
        with self.assertRaises(matching.MatchError):
            matching.match(pages, self.decisions)


if __name__ == "__main__":
    unittest.main()
