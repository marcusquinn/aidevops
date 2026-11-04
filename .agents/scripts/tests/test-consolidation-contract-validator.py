#!/usr/bin/env python3
"""Scoped regression checks for consolidation's local publication contract."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

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
MARKER = "_Supersedes #1 — this issue is the consolidated spec._"
SUCCESSOR = f"{MARKER}\n\n{SOURCE}"


def run_main(argv: list[str]) -> tuple[int, str]:
    """Run the validator CLI in-process (no extra subprocess); return (exit code, stderr)."""
    stderr = io.StringIO()
    with mock.patch.object(sys, "argv", argv), redirect_stderr(stderr), redirect_stdout(io.StringIO()):
        try:
            code = VALIDATOR.main()
        except SystemExit as exc:
            code = exc.code
    return code, stderr.getvalue()


class ContractTests(unittest.TestCase):
    def test_preserved_contract_passes(self):
        self.assertEqual(VALIDATOR.validate([SOURCE], SUCCESSOR), [])

    def test_successor_requires_exact_marker_line(self):
        self.assertTrue(VALIDATOR.validate([SOURCE], SOURCE))
        prose = "This issue supersedes #1.\n\n" + SOURCE
        self.assertTrue(VALIDATOR.validate([SOURCE], prose))
        trailing = SUCCESSOR.replace("spec._", "spec. #1 itself superseded #0._", 1)
        errors = VALIDATOR.validate([SOURCE], trailing)
        self.assertTrue(any("separate line" in error for error in errors))
        self.assertTrue(VALIDATOR.validate([SOURCE], SUCCESSOR.replace("spec._", "spec._ ", 1)))
        self.assertTrue(VALIDATOR.validate([SOURCE], SUCCESSOR.replace("\n", "\r\n")))
        ascii_dash = SUCCESSOR.replace("—", "-", 1)
        self.assertEqual(VALIDATOR.validate([SOURCE], ascii_dash), [])
        lineage = SUCCESSOR.replace(MARKER, MARKER + "\n#1 itself superseded #0.", 1)
        self.assertEqual(VALIDATOR.validate([SOURCE], lineage), [])

    def test_marker_numbers_must_match_parents(self):
        self.assertEqual(VALIDATOR.validate([SOURCE], SUCCESSOR, [1]), [])
        self.assertIn("successor: marker references #1, which is not a --parent",
                      VALIDATOR.validate([SOURCE], SUCCESSOR, [2]))
        self.assertIn("successor: missing exact marker line for parent #2",
                      VALIDATOR.validate([SOURCE, SOURCE], SUCCESSOR, [1, 2]))
        both = MARKER.replace("#1", "#2") + "\n" + SUCCESSOR
        self.assertEqual(VALIDATOR.validate([SOURCE, SOURCE], both, [1, 2]), [])

    def test_every_source_contributes_to_union(self):
        other = "requires-secrets: B, C\n"
        self.assertEqual(VALIDATOR.validate([SOURCE, other], SUCCESSOR + "\n" + other), [])
        self.assertTrue(VALIDATOR.validate([SOURCE, other], SUCCESSOR))

    def test_secret_summary_does_not_replace_verbatim_lines(self):
        successor = SUCCESSOR.replace("requires-secrets: A B", "requires-secrets: A, B")
        self.assertIn("source 1: missing verbatim requires-secrets line",
                      VALIDATOR.validate([SOURCE], successor))

    def test_prerequisite_paragraph_is_preserved(self):
        successor = SUCCESSOR.replace("Use a runner with ordinary test credentials.\n", "")
        self.assertIn("source 1: missing verbatim runner-prerequisite paragraph",
                      VALIDATOR.validate([SOURCE], successor))

    def test_generated_scope_must_remain_wildcard(self):
        successor = SUCCESSOR.replace("log/*/*/x-*.jsonl", "log/consolidated/2026-10-05/x-history.jsonl")
        self.assertIn("source 1: missing verbatim wildcard Files Scope entry",
                      VALIDATOR.validate([SOURCE], successor))

    def test_pattern_in_prose_does_not_count_as_scope(self):
        successor = SUCCESSOR.replace("- NEW: log/*/*/x-*.jsonl\n", "")
        successor += "\n- NEW: log/*/*/x-*.jsonl\n"
        self.assertTrue(VALIDATOR.validate([SOURCE], successor))

    def test_edit_cannot_be_changed_to_new(self):
        successor = SUCCESSOR.replace("EDIT: src/existing.sh", "NEW: src/existing.sh")
        self.assertIn("source 1: EDIT scope entry changed to NEW",
                      VALIDATOR.validate([SOURCE], successor))

    def test_backtick_scope_and_multiple_sections(self):
        source = SOURCE.replace("- EDIT: src/existing.sh", "- `EDIT: src/existing.sh`")
        source += "\n### Files Scope\n- `NEW: other/[ab]/x-?.jsonl`\n"
        self.assertEqual(VALIDATOR.validate([source], f"{MARKER}\n\n{source}"), [])
        self.assertTrue(VALIDATOR.validate([source], SUCCESSOR))

    def test_no_contract_is_compatible(self):
        self.assertEqual(VALIDATOR.validate(["## What\nPlain issue"], f"{MARKER}\nPlain successor"), [])

    def test_cli_checks_all_sources_and_fails_closed(self):
        temp_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(dir=temp_root) as temp:
            root = Path(temp)
            source = root / "source.md"
            other = root / "other.md"
            successor = root / "successor.md"
            source.write_text(SOURCE, encoding="utf-8")
            other.write_text("requires-secrets: C\n", encoding="utf-8")
            both = MARKER.replace("#1", "#2") + "\n" + SUCCESSOR
            successor.write_text(both + "\nrequires-secrets: C\n", encoding="utf-8")
            command = [sys.executable, str(SCRIPT), "--parent", "1", "--source", str(source),
                       "--parent", "2", "--source", str(other), "--successor", str(successor)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            successor.write_text(SOURCE + "\nrequires-secrets: C\n", encoding="utf-8")
            code, stderr = run_main(command[1:])
            self.assertEqual(code, 1)
            self.assertIn(VALIDATOR.MARKER_EXAMPLE, stderr)
            successor.write_text(SUCCESSOR, encoding="utf-8")
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
            other.unlink()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(str(root), result.stderr)

    def test_cli_rejects_missing_extra_and_duplicate_parents(self):
        temp_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(dir=temp_root) as temp:
            root = Path(temp)
            source = root / "source.md"
            successor = root / "successor.md"
            source.write_text(SOURCE, encoding="utf-8")
            successor.write_text(SUCCESSOR, encoding="utf-8")
            command = [sys.executable, str(SCRIPT), "--successor", str(successor)]
            for parents, source_count in [([], 1), ([1], 2), ([1, 2], 1), ([1, 1], 2)]:
                with self.subTest(parents=parents, source_count=source_count):
                    args = command + [arg for parent in parents for arg in ("--parent", str(parent))]
                    args += [arg for _ in range(source_count) for arg in ("--source", str(source))]
                    code, stderr = run_main(args[1:])
                    self.assertEqual(code, 2)
                    self.assertIn("one unique issue number for each --source", stderr)

    def test_cli_preserves_crlf_for_marker_check(self):
        temp_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(dir=temp_root) as temp:
            root = Path(temp)
            source = root / "source.md"
            successor = root / "successor.md"
            source.write_bytes(SOURCE.replace("\n", "\r\n").encode("utf-8"))
            successor.write_bytes(SUCCESSOR.replace("\n", "\r\n").encode("utf-8"))
            command = [sys.executable, str(SCRIPT), "--parent", "1", "--source", str(source),
                       "--successor", str(successor)]
            code, stderr = run_main(command[1:])
            self.assertEqual(code, 1)
            self.assertIn("missing exact marker line", stderr)
            self.assertNotIn("source 1:", stderr)
            # A valid LF marker with matching CRLF contracts still passes.
            successor.write_bytes((MARKER + "\n\n" + SOURCE.replace("\n", "\r\n")).encode("utf-8"))
            self.assertEqual(run_main(command[1:])[0], 0)
            # Contract comparisons accept either direction of mixed line endings.
            successor.write_bytes(SUCCESSOR.encode("utf-8"))
            self.assertEqual(run_main(command[1:])[0], 0)
            source.write_bytes(SOURCE.encode("utf-8"))
            successor.write_bytes((MARKER + "\n\n" + SOURCE.replace("\n", "\r\n")).encode("utf-8"))
            self.assertEqual(run_main(command[1:])[0], 0)


if __name__ == "__main__":
    unittest.main()
