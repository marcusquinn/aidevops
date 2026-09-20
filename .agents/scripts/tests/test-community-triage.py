#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused tests for offline, non-mutating community triage."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("community_triage", SCRIPTS / "community_triage.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("community triage module is unavailable")
triage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(triage)


class CommunityTriageTests(unittest.TestCase):
    def run_fixture(self) -> dict:
        return triage.analyze(FIXTURES / "community-input.json", FIXTURES / "community-decisions.json")

    def test_routes_complaints_questions_and_injected_text_without_actions(self):
        report = self.run_fixture()
        results = {row["source_id"]: row for row in report["results"]}
        self.assertEqual(results["comment-1"]["owner"], "support")
        self.assertEqual(results["thread-1"]["categories"], ["question", "buyer_opportunity"])
        self.assertEqual(results["comment-2"]["categories"], ["unknown"])
        self.assertEqual(results["comment-2"]["urgency_reason"], "untrusted_instruction_text")
        self.assertTrue(all(row["external_action"] == "prohibited" for row in results.values()))

    def test_missing_decision_stays_reviewable_and_edits_require_new_version(self):
        payload = json.loads((FIXTURES / "community-input.json").read_text())
        payload["items"] = payload["items"][:1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path, decision_path = root / "input.json", root / "decisions.json"
            input_path.write_text(json.dumps(payload))
            decision_path.write_text('{"schema":"aidevops.community-triage-decisions/v1","decisions":[]}')
            report = triage.analyze(input_path, decision_path)
        self.assertEqual(report["results"][0]["urgency_reason"], "insufficient_context")
        payload["items"].append({**payload["items"][0], "text": "changed"})
        with self.assertRaises(triage.TriageError):
            triage.validate_input(payload)


if __name__ == "__main__":
    unittest.main()
