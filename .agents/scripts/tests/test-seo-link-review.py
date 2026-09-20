#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused offline tests for evidence-backed link review."""

from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("seo_link_review", SCRIPTS / "seo_link_review.py")
review = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise ImportError("unable to load seo_link_review")
SPEC.loader.exec_module(review)


class LinkReviewTests(unittest.TestCase):
    def pages(self):
        return json.loads((FIXTURES / "links-pages.json").read_text())

    def test_proposals_are_observed_and_non_mutating(self):
        report = review.analyze(self.pages())
        self.assertTrue(report["link_proposals"])
        proposal = report["link_proposals"][0]
        self.assertTrue(proposal["anchor"])
        self.assertTrue(proposal["evidence_id"].startswith("sha256:"))
        self.assertTrue(proposal["non_mutating"])

    def test_existing_links_invalid_destinations_and_anchor_changes_are_safe(self):
        data = self.pages()
        data["pages"][0]["links"] = ["/pricing"]
        self.assertNotIn("/pricing", [item["destination_url"] for item in review.analyze(data)["link_proposals"] if item["source_url"] == "/guide"])
        data = self.pages()
        data["pages"][1]["status"] = 404
        with self.assertRaises(review.ReviewError):
            review.analyze(data)
        first = review.analyze(self.pages())["link_proposals"]
        changed = self.pages()
        changed["pages"][0]["body"] = "A different SEO audit explanation."
        self.assertNotEqual(first, review.analyze(changed)["link_proposals"])

    def test_overlap_is_not_automatically_harmful_and_unknown_abstains(self):
        report = review.analyze(self.pages())
        by_query = {item["query"]: item for item in report["cannibalization"]}
        self.assertEqual(by_query["seo audit pricing"]["classification"], "duplication")
        self.assertEqual(by_query["seo audit"]["classification"], "complementary")
        data = self.pages()
        data["query_pairs"].append({"query":"unknown","urls":["/guide","/missing"],"source":{"source_id":"gsc","span":"row-9"},"metrics":{}})
        self.assertEqual(review.analyze(data)["cannibalization"][-1]["classification"], "unknown")


if __name__ == "__main__":
    unittest.main()
