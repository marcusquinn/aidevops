#!/usr/bin/env python3
"""Focused tests for offline marketing snapshot imports."""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("snapshot", SCRIPTS / "marketing_snapshot_imports.py")
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)


class SnapshotImportTests(unittest.TestCase):
    def test_google_preserves_unknowns_and_censorship(self):
        result = snapshot.normalize("google-ads", FIXTURES / "import-google.csv")
        self.assertEqual(len(result["records"]), 2)
        self.assertIsNone(result["records"][0]["metrics"]["conversions"])
        self.assertEqual(result["records"][0]["query_coverage"], "censored")
        self.assertEqual(result["records"][0]["metrics"]["spend_micros"], 1234567)

    def test_json_and_duplicate_errors_retain_evidence(self):
        result = snapshot.normalize("meta", FIXTURES / "import-all.json")
        self.assertEqual(result["records"][0]["metrics"]["spend"], "12.34")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bad.json"
            source.write_text(json.dumps([{"id": "same"}, {"id": "same"}]), encoding="utf-8")
            result = snapshot.normalize("site", source)
        self.assertEqual(len(result["row_errors"]), 1)

    def test_every_json_kind_and_context_is_offline_importable(self):
        for kind in ("meta", "gsc", "site", "ai-capture", "community"):
            with self.subTest(kind=kind):
                result = snapshot.normalize(kind, FIXTURES / "import-all.json", {
                    "scope": "account-1", "date_start": "2026-01-01", "date_end": "2026-01-31",
                    "timezone": "UTC", "currency": "USD",
                })
                self.assertEqual(result["scope"], "account-1")
                self.assertEqual(result["currency"], "USD")

    def test_ambiguous_units_are_row_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "bad.json"
            source.write_text(json.dumps([{"id": "same", "spend": "1", "cost_micros": "2"}]), encoding="utf-8")
            result = snapshot.normalize("meta", source)
        self.assertEqual(result["row_errors"][0]["reason"], "ambiguous spend units")


if __name__ == "__main__":
    unittest.main()
