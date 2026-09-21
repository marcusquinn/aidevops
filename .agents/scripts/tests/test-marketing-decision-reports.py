#!/usr/bin/env python3
"""Focused contracts for decision-report aggregation and holdout evaluation."""

import json
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from marketing_decision_reports import DecisionReportError, build_report, evaluate_holdout  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures" / "marketing-decisions"


class DecisionReportTests(unittest.TestCase):
    def test_report_separates_unknown_economics_and_per_engine_output(self):
        report = build_report(json.loads((FIXTURES / "report-input.json").read_text()))
        self.assertEqual("observational_unless_separately_approved_experiment", report["causality"])
        self.assertEqual("chatgpt", report["recommendations"][0]["engine"])
        self.assertIsNone(report["recommendations"][0]["economics"]["known_cost"])

    def test_evaluation_rejects_synthetic_ground_truth(self):
        data = json.loads((FIXTURES / "report-holdout.json").read_text())
        data["labels"][0]["synthetic"] = True
        with self.assertRaises(DecisionReportError):
            evaluate_holdout(data)

    def test_evaluation_preserves_unknown_costs(self):
        evaluation = evaluate_holdout(json.loads((FIXTURES / "report-holdout.json").read_text()))
        self.assertIsNone(evaluation["total_known_cost"])
        self.assertEqual("not_claimed_without_predeclared_bins", evaluation["calibration"])

    def test_report_rejects_mixed_currencies(self):
        data = json.loads((FIXTURES / "report-input.json").read_text())
        data["recommendations"][0]["economics"]["currency"] = "EUR"
        with self.assertRaises(DecisionReportError):
            build_report(data)


if __name__ == "__main__":
    unittest.main()
