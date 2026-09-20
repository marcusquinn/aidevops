#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused tests for offline creative intelligence safeguards."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("creative_intelligence", SCRIPTS / "creative_intelligence.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class CreativeIntelligenceTests(unittest.TestCase):
    def test_snapshot_preserves_unknowns_and_non_mutating_recommendations(self):
        report = module.analyze(json.loads((FIXTURES / "creative-manifest.json").read_text()), json.loads((FIXTURES / "creative-decisions.json").read_text()))
        self.assertEqual(report["authority"], "recommendations_only")
        self.assertEqual(len(report["concept_groups"]), 1)
        self.assertEqual(report["grouped_outcomes"][0]["cpa"], 20)
        self.assertEqual(report["fatigue"][0]["verdict"], "refresh_hypothesis")
        self.assertEqual(report["fatigue"][1]["verdict"], "review")
        self.assertEqual(report["competitor_observations"][0]["profitability"], "unknown")
        first = report["policy_and_ugc_precheck"][0]
        self.assertEqual(first["provider_approval"], "unknown")
        self.assertEqual(first["requirements"][1]["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
