#!/usr/bin/env python3
"""Focused tests for offline content disposition safeguards."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("disposition", SCRIPTS / "seo_content_disposition.py")
disposition = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(disposition)


class ContentDispositionTests(unittest.TestCase):
    def test_protected_unknown_and_redirect_safeguards(self):
        report = disposition.review(json.loads((FIXTURES / "disposition-pages.json").read_text()), json.loads((FIXTURES / "disposition-decisions.json").read_text()))
        outcomes = {item["page_id"]: item for item in report["results"]}
        self.assertEqual(outcomes["protected"]["outcome"], "keep")
        self.assertEqual(outcomes["unknown"]["outcome"], "abstain")
        self.assertEqual(outcomes["thin"]["outcome"], "merge")
        self.assertTrue(outcomes["thin"]["migration_proposal"]["non_mutating"])
        self.assertEqual(outcomes["thin"]["schema_findings"][0]["kind"], "visible_consistency")

    def test_cli_requires_dry_run_and_emits_non_mutating_report(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "seo-content-disposition-helper.py"), "review", "--input", str(FIXTURES / "disposition-pages.json"), "--decisions", str(FIXTURES / "disposition-decisions.json"), "--dry-run"], check=True, capture_output=True, text=True)  # nosec B603
        self.assertEqual(json.loads(result.stdout)["authority"], "non_mutating_recommendations_only")

    def test_looping_or_unmatched_redirects_are_rejected(self):
        pages = json.loads((FIXTURES / "disposition-pages.json").read_text())
        pages["pages"][2]["replacement_url"] = "/old-guide"
        report = disposition.review(pages, json.loads((FIXTURES / "disposition-decisions.json").read_text()))
        thin = next(item for item in report["results"] if item["page_id"] == "thin")
        self.assertEqual((thin["outcome"], thin["reason"]), ("update", "redirect_loop"))

    def test_retired_page_is_a_review_only_remove_proposal(self):
        pages = json.loads((FIXTURES / "disposition-pages.json").read_text())
        pages["pages"][2]["status"] = 410
        report = disposition.review(pages, json.loads((FIXTURES / "disposition-decisions.json").read_text()))
        thin = next(item for item in report["results"] if item["page_id"] == "thin")
        self.assertEqual((thin["outcome"], thin["reason"]), ("remove", "retired_page_confirmed"))
        self.assertTrue(thin["non_mutating"])


if __name__ == "__main__":
    unittest.main()
