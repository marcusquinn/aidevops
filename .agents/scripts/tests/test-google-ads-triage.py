#!/usr/bin/env python3
"""Focused tests for offline Google Ads hygiene triage."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("triage", SCRIPTS / "google-ads-triage-helper.py")
triage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(triage)


class GoogleAdsTriageTests(unittest.TestCase):
    def test_match_semantics_are_explicit_not_semantic(self):
        self.assertTrue(triage.negative_blocks("free shoe repair", {"term": "free shoe", "match_type": "phrase"}))
        self.assertTrue(triage.negative_blocks("free shoe repair", {"term": "repair free", "match_type": "broad"}))
        self.assertFalse(triage.negative_blocks("shoe repairs", {"term": "shoe repair", "match_type": "exact"}))
        self.assertFalse(triage.negative_blocks("complimentary shoe repair", {"term": "free repair", "match_type": "broad"}))

    def test_converting_and_missing_terms_remain_reviewable(self):
        account = json.loads((FIXTURES / "google-account.json").read_text())
        report = triage.analyze(account, {"request_id": "fixture"})
        self.assertEqual(set(report["coverage"]), set(triage.JOBS))
        conflict = next(item for item in report["results"] if item["job"] == "negative_conflict" and item["evidence"]["term_id"] == "term-1")
        self.assertEqual(conflict["outcome"], "review")
        unknown = next(item for item in report["results"] if item["job"] == "recommendation_routing" and item["evidence"]["term_id"] == "term-2")
        self.assertEqual(unknown["outcome"], "review")
        self.assertTrue(all(item["non_mutating"] for item in report["results"]))

    def test_cli_runs_the_synthetic_snapshot(self):
        result = subprocess.run(  # nosec B603 - fixed interpreter and repository-controlled fixture paths
            [
                sys.executable,
                str(SCRIPTS / "google_ads_triage.py"),
                "analyze",
                "--input",
                str(FIXTURES / "google-account.json"),
                "--decisions",
                str(FIXTURES / "google-decisions.json"),
                "--dry-run",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(json.loads(result.stdout)["authority"], "non_mutating_recommendations_only")


if __name__ == "__main__":
    unittest.main()
