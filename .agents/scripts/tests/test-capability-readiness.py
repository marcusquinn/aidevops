#!/usr/bin/env python3
"""Unit and drift tests for the capability readiness contract."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TEST_DIR = Path(__file__).resolve().parent
HELPER = TEST_DIR.parent / "capability-readiness-helper.py"
FIXTURE = TEST_DIR / "fixtures" / "capability-readiness-states.json"


class CapabilityReadinessTests(unittest.TestCase):
    def run_helper(self, *args: str, expected: int = 0) -> dict:
        result = subprocess.run([sys.executable, str(HELPER), "--fixture", str(FIXTURE), *args], text=True, capture_output=True, check=False)  # nosec B603
        self.assertEqual(expected, result.returncode, result.stderr or result.stdout)
        return json.loads(result.stdout) if result.stdout else {}

    def test_registry_has_no_drift(self) -> None:
        result = subprocess.run([sys.executable, str(HELPER), "check"], text=True, capture_output=True, check=False)  # nosec B603
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertTrue(json.loads(result.stdout)["valid"])

    def test_healthy_capability_routes(self) -> None:
        output = self.run_helper("route", "code", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Build+", output["owner"])

    def test_unavailable_credentials_fall_back(self) -> None:
        output = self.run_helper("route", "github", "--runtime", "opencode", expected=3)
        self.assertEqual("fallback", output["decision"])
        self.assertIn("authenticated", output["coverage_impact"])

    def test_unreachable_service_falls_back(self) -> None:
        output = self.run_helper("route", "seo-data", "--runtime", "opencode", expected=3)
        self.assertIn("reachable", output["coverage_impact"])

    def test_missing_permission_falls_back(self) -> None:
        output = self.run_helper("route", "cloudflare", "--runtime", "opencode", expected=3)
        self.assertIn("authorized", output["coverage_impact"])

    def test_hidden_tool_falls_back(self) -> None:
        output = self.run_helper("route", "browser", "--runtime", "opencode", expected=3)
        self.assertIn("tool_visible", output["coverage_impact"])

    def test_generated_index_is_stable(self) -> None:
        committed = HELPER.parents[1] / "reference" / "capability-registry.md"
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / "index.md"
            subprocess.run([sys.executable, str(HELPER), "generate", "--output", str(generated)], check=True)  # nosec B603
            self.assertEqual(committed.read_text(), generated.read_text())


if __name__ == "__main__":
    unittest.main()
