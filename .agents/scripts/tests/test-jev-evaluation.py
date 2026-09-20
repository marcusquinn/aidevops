#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline contracts for the manual Jev evaluation journal."""

import contextlib
import importlib.util
import io
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jev_evaluation", SCRIPTS / "jev-evaluation.py")
journal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(journal)


def sample(route="baseline", provenance="operator_reviewed"):
    return {"task_id": "heldout-01", "task_category": "retrieval", "route": route,
            "accepted_outcome": "accepted", "label_provenance": provenance,
            "corpus_sha256": "a" * 64, "rubric": "2026.09", "model": "offline",
            "metrics": {"repair_seconds": None, "end_to_end_seconds": 12, "input_tokens": None,
                        "total_cost_usd": 0.0}, "missing_evidence": False, "misclassification": False}


class JournalTests(unittest.TestCase):
    def setUp(self):
        root = Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="jev-evaluation-test-", dir=root)
        self.addCleanup(self.temp.cleanup)
        self.home_patch = patch.object(journal.Path, "home", return_value=Path(self.temp.name))
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)

    def invoke(self, *args):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = journal.main(list(args))
        return code, json.loads(output.getvalue())

    def input_file(self, data):
        path = Path(self.temp.name) / "record.json"
        path.write_text(json.dumps(data))
        return path

    def test_record_is_private_offline_and_unknown_is_not_zero(self):
        code, result = self.invoke("record", "--input", str(self.input_file(sample())))
        self.assertEqual(code, 0)
        path = Path(result["private_record"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertIsNone(json.loads(path.read_text())["metrics"]["repair_seconds"])
        self.assertTrue(result["manual_only"])
        self.assertEqual(self.invoke("status"), (0, {"status": "local_only", "records": 1, "manual_only": True}))

    def test_duplicate_record_is_rejected_without_overwrite(self):
        source = self.input_file(sample())
        self.assertEqual(self.invoke("record", "--input", str(source))[0], 0)
        self.assertEqual(self.invoke("record", "--input", str(source))[0], 2)
        self.assertEqual(self.invoke("status")[1]["records"], 1)

    def test_record_rejects_git_checkout_storage(self):
        (Path(self.temp.name) / ".git").mkdir()
        code, result = self.invoke("record", "--input", str(self.input_file(sample())))
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "invalid_input_or_private_storage")

    def test_compare_requires_compatible_reviewed_pairs(self):
        baseline = journal.validate_record(sample())
        pilot = journal.validate_record(sample("jev"))
        self.assertEqual(journal.compare(baseline, pilot)["status"], "comparable")
        pilot["corpus_sha256"] = "b" * 64
        result = journal.compare(baseline, pilot)
        self.assertEqual(result["status"], "not_comparable")
        self.assertIn("corpus_sha256", result["mismatched_fields"])
        self.assertEqual(journal.compare(baseline, journal.validate_record(sample("jev", "unreviewed")))["status"], "not_comparable")

    def test_selected_pilot_report_is_validated(self):
        report = Path(self.temp.name) / "pilot.json"
        report.write_text(json.dumps({"schema": journal.PILOT_SCHEMA, "corpus_sha256": "a" * 64,
                                      "rubric": "2026.09", "model": "offline"}))
        data = sample()
        del data["corpus_sha256"], data["rubric"], data["model"]
        code, _ = self.invoke("record", "--input", str(self.input_file(data)), "--pilot-report", str(report))
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
