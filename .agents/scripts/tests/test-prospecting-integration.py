#!/usr/bin/env python3
"""Offline parity chain: existing contracts remain local and non-mutating."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / ".agents" / "scripts"
FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "integration.json"


class ProspectingIntegrationTest(unittest.TestCase):
    def test_offline_chain_has_private_non_delivery_surfaces(self) -> None:
        scenario = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.assertEqual("aidevops.prospecting-integration/v1", scenario["schema"])
        self.assertFalse(scenario["external_messages"])
        self.assertEqual(9, len(scenario["stages"]))
        for path in (
            ROOT / ".agents" / "marketing-sales" / "prospecting.md",
            ROOT / ".agents" / "scripts" / "commands" / "prospecting.md",
            ROOT / ".agents" / "services" / "hosting" / "prospecting-self-host.md",
            ROOT / ".agents" / "templates" / "prospecting-container" / "compose.yaml",
        ):
            self.assertTrue(path.is_file(), path)

    def test_existing_offline_contracts_execute(self) -> None:
        commands = (
            "test-prospecting-store.py",
            "test-prospecting-profile.py",
            "test-prospecting-scan.py",
            "test-prospecting-seo.py",
            "test-prospecting-insights.py",
            "test-prospecting-routines.py",
            "test-prospecting-api.py",
        )
        for command in commands:
            completed = subprocess.run(  # nosec B603: fixed local contract tests
                [sys.executable, str(SCRIPTS / "tests" / command)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)


if __name__ == "__main__":
    unittest.main()
