#!/usr/bin/env python3
"""Offline integration contract for the marketing decision handoff."""

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / ".agents" / "scripts"
FIXTURES = Path(__file__).parent / "fixtures" / "marketing-decisions"


class MarketingDecisionIntegrationTests(unittest.TestCase):
    def run_cli(self, script, *args):
        completed = subprocess.run(  # nosec B603 -- fixed repository helper and fixture paths
            [sys.executable, str(SCRIPTS / script), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        return completed.stdout

    def test_offline_chain_preserves_coverage_and_non_mutation(self):
        fixture = json.loads((FIXTURES / "integration-input.json").read_text())
        self.assertEqual("offline", fixture["mode"])
        self.assertEqual(33, len(fixture["article_jobs"]))
        self.assertEqual(set(fixture["article_jobs"]) | {"paid_to_organic_bridge"}, set(fixture["coverage"]))
        self.assertTrue(any(value.startswith("unsupported:") for value in fixture["coverage"].values()))
        self.assertEqual(3, len(fixture["live_activation_prerequisites"]))
        report = self.run_cli("marketing-decision-report-helper.py", "report", "--input", str(FIXTURES / "report-input.json"), "--dry-run")
        self.assertIn("unknown", report.lower())
        actions = self.run_cli("marketing-action-helper.py", "plan", "--input", str(FIXTURES / "actions-plan.json"), "--dry-run")
        self.assertIn("handoff", actions.lower())


if __name__ == "__main__":
    unittest.main()
