#!/usr/bin/env python3
from __future__ import annotations
import copy
import json
import sys
import unittest
from pathlib import Path
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from prospecting_seo import SeoError, refresh  # noqa: E402
FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "serp.json"

class ProspectingSeoTest(unittest.TestCase):
    def setUp(self) -> None:
        self.document = json.loads(FIXTURE.read_text())

    def test_history_preserves_organic_and_filtered_scope(self) -> None:
        report = refresh(self.document)
        organic = next(item for item in report["opportunities"] if item["query_id"] == "q1")
        filtered = next(item for item in report["opportunities"] if item["query_id"] == "q2")
        self.assertEqual([4, 2], [item["rank"] for item in organic["history"]])
        self.assertEqual(-2, organic["rank_change"])
        self.assertEqual("global_organic", organic["rank_scope"])
        self.assertEqual("filtered_discovery_only", filtered["rank_scope"])
        self.assertEqual("not_measured", organic["claims"]["ai_citation"])

    def test_failure_never_becomes_rank_loss(self) -> None:
        report = refresh(self.document)
        self.assertEqual("not_compared_as_rank_loss", report["incomplete_runs"][0]["reason"])

    def test_invalid_result_position_is_rejected(self) -> None:
        malformed = copy.deepcopy(self.document)
        malformed["runs"][0]["results"][0]["position"] = 0
        with self.assertRaises(SeoError):
            refresh(malformed)

if __name__ == "__main__":
    unittest.main()
