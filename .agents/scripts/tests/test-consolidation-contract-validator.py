#!/usr/bin/env python3
"""Scoped regression checks for consolidation's local publication contract."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "consolidation-contract-validator.py"
SPEC = importlib.util.spec_from_file_location("contract_validator", SCRIPT)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)

SOURCE = """## Runner prerequisite

Use a runner with ordinary test credentials.
requires-secrets: A B

### Files Scope
- NEW: log/*/*/x-*.jsonl
- EDIT: src/existing.sh

## How
Use the append helper; it selects machine, date and timestamp.
"""


class ContractTests(unittest.TestCase):
    def test_preserved_contract_passes(self):
        self.assertEqual(VALIDATOR.validate([SOURCE], SOURCE), [])

    def test_every_source_contributes_to_union(self):
        other = "requires-secrets: B, C\n"
        self.assertEqual(VALIDATOR.validate([SOURCE, other], SOURCE + "\n" + other), [])
        self.assertTrue(VALIDATOR.validate([SOURCE, other], SOURCE))

    def test_secret_summary_does_not_replace_verbatim_lines(self):
        successor = SOURCE.replace("requires-secrets: A B", "requires-secrets: A, B")
        self.assertIn("source 1: missing verbatim requires-secrets line",
                      VALIDATOR.validate([SOURCE], successor))

    def test_prerequisite_paragraph_is_preserved(self):
        successor = SOURCE.replace("Use a runner with ordinary test credentials.\n", "")
        self.assertIn("source 1: missing verbatim runner-prerequisite paragraph",
                      VALIDATOR.validate([SOURCE], successor))

    def test_generated_scope_must_remain_wildcard(self):
        successor = SOURCE.replace("log/*/*/x-*.jsonl", "log/consolidated/2026-10-05/x-history.jsonl")
        self.assertIn("source 1: missing verbatim wildcard Files Scope entry",
                      VALIDATOR.validate([SOURCE], successor))

    def test_pattern_in_prose_does_not_count_as_scope(self):
        successor = SOURCE.replace("- NEW: log/*/*/x-*.jsonl\n", "")
        successor += "\n- NEW: log/*/*/x-*.jsonl\n"
        self.assertTrue(VALIDATOR.validate([SOURCE], successor))

    def test_edit_cannot_be_changed_to_new(self):
        successor = SOURCE.replace("EDIT: src/existing.sh", "NEW: src/existing.sh")
        self.assertIn("source 1: EDIT scope entry changed to NEW",
                      VALIDATOR.validate([SOURCE], successor))

    def test_backtick_scope_and_multiple_sections(self):
        source = SOURCE.replace("- EDIT: src/existing.sh", "- `EDIT: src/existing.sh`")
        source += "\n### Files Scope\n- `NEW: other/[ab]/x-?.jsonl`\n"
        self.assertEqual(VALIDATOR.validate([source], source), [])
        self.assertTrue(VALIDATOR.validate([source], SOURCE))

    def test_no_contract_is_compatible(self):
        self.assertEqual(VALIDATOR.validate(["## What\nPlain issue"], "Plain successor"), [])

    def test_cli_checks_all_sources_and_fails_closed(self):
        temp_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(dir=temp_root) as temp:
            root = Path(temp)
            source = root / "source.md"
            other = root / "other.md"
            successor = root / "successor.md"
            source.write_text(SOURCE, encoding="utf-8")
            other.write_text("requires-secrets: C\n", encoding="utf-8")
            successor.write_text(SOURCE + "\nrequires-secrets: C\n", encoding="utf-8")
            command = [sys.executable, str(SCRIPT), "--source", str(source),
                       "--source", str(other), "--successor", str(successor)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            successor.write_text(SOURCE, encoding="utf-8")
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
            other.unlink()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(str(root), result.stderr)


if __name__ == "__main__":
    unittest.main()
