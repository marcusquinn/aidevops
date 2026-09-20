#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused tests for offline evidence-linked prospecting insights."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "insights.json"
SPEC = importlib.util.spec_from_file_location("prospecting_insights", SCRIPTS / "prospecting_insights.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("prospecting insights module is unavailable")
insights = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(insights)


class ProspectingInsightsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def derive_fixture(self) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path, decisions_path = root / "input.json", root / "decisions.json"
            input_path.write_text(json.dumps(self.fixture["input"]), encoding="utf-8")
            decisions_path.write_text(json.dumps(self.fixture["decisions"]), encoding="utf-8")
            return insights.derive(input_path, decisions_path)

    def test_fixture_derives_multi_entity_evidence_without_author_attribution(self):
        report = self.derive_fixture()
        acme = next(row for row in report["competitors"] if row["entity"] == "Acme")
        self.assertEqual(2, acme["observation_count"])
        self.assertEqual(1, acme["thread_count"])
        self.assertEqual("unknown", acme["evidence"][1]["sentiment"])
        self.assertEqual(3, report["coverage"]["observation_count"])
        self.assertEqual("prohibited", report["handoffs"]["outreach"])

    def test_invalid_decision_and_cli_dry_run_are_bounded(self):
        bad = copy.deepcopy(self.fixture["decisions"])
        bad["decisions"][0]["themes"][0]["target"] = "yes"
        with self.assertRaises(insights.InsightError):
            insights.validate_decisions(bad, {"post-1", "comment-1", "comment-2"})
        result = subprocess.run(["python3", str(SCRIPTS / "prospecting-insights-helper.py"), "--help"], check=True, capture_output=True, text=True)
        self.assertIn("derive", result.stdout)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path, decisions_path = root / "input.json", root / "decisions.json"
            input_path.write_text(json.dumps(self.fixture["input"]), encoding="utf-8")
            decisions_path.write_text(json.dumps(self.fixture["decisions"]), encoding="utf-8")
            derived = subprocess.run(["python3", str(SCRIPTS / "prospecting-insights-helper.py"), "derive", "--input", str(input_path), "--decisions", str(decisions_path), "--dry-run"], check=True, capture_output=True, text=True)
        self.assertEqual("aidevops.prospecting-insights-report/v1", json.loads(derived.stdout)["schema"])

    def test_comparison_requires_matching_rubric_and_exposes_coverage(self):
        report = self.derive_fixture()
        incompatible = copy.deepcopy(report)
        incompatible["snapshot"]["rubric_version"] = "insights-2"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline, current = root / "baseline.json", root / "current.json"
            baseline.write_text(json.dumps(report), encoding="utf-8")
            current.write_text(json.dumps(incompatible), encoding="utf-8")
            comparison = insights.compare(baseline, current)
        self.assertFalse(comparison["comparison"]["available"])
        self.assertEqual("rubric_version_mismatch", comparison["comparison"]["reason"])


if __name__ == "__main__":
    unittest.main()
