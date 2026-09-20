#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused offline tests for AI visibility capture analysis."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("visibility", SCRIPTS / "ai_visibility.py")
visibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(visibility)


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class VisibilityTests(unittest.TestCase):
    def test_separates_mentions_recommendations_citations_and_failures(self):
        report = visibility.analyze(fixture("visibility-answers.json"), fixture("visibility-decisions.json"))
        chatgpt = next(line for line in report["engine_mode_cohort_lines"] if line["engine"] == "ChatGPT")
        gemini = next(line for line in report["engine_mode_cohort_lines"] if line["engine"] == "Gemini")
        self.assertEqual(chatgpt["valid_answers"], 2)
        self.assertEqual(chatgpt["mentions"], {"Acme Analytics": 2, "Rival Metrics": 1})
        self.assertEqual(chatgpt["recommendations"], {"Acme Analytics": 1, "Rival Metrics": 1})
        self.assertEqual(chatgpt["citation_count"], 2)
        self.assertEqual(gemini["valid_answers"], 0)
        self.assertEqual(gemini["unavailable"], 1)

    def test_unknown_models_and_invalid_complete_answers_are_explicit(self):
        data = fixture("visibility-answers.json")
        report = visibility.analyze(data, fixture("visibility-decisions.json"))
        self.assertEqual(report["observations"][0]["model"], "unknown")
        data["captures"][0]["answer"] = None
        with self.assertRaises(visibility.VisibilityError):
            visibility.analyze(data, fixture("visibility-decisions.json"))


if __name__ == "__main__":
    unittest.main()
