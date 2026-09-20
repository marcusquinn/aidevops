#!/usr/bin/env python3
"""Focused contract tests for read-only marketing account collection."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


google = load("marketing_account_google")
meta = load("marketing_account_meta")


class Response:
    def __init__(self, value): self.value = value
    def read(self, _limit): return json.dumps(self.value).encode()


class AccountSnapshotTests(unittest.TestCase):
    def test_google_uses_only_fixed_read_endpoint(self):
        captured = []
        result = google.collect("123-456-7890", "2026-01-01", "2026-01-02", "token", "developer", lambda request: captured.append(request) or Response([{"campaign": {"id": "1"}}]))
        self.assertEqual(result["records"][0]["campaign"]["id"], "1")
        self.assertTrue(captured[0].full_url.endswith(":searchStream"))
        self.assertEqual(captured[0].method, "POST")

    def test_meta_gets_fixed_insights_and_marks_partial_paging(self):
        result = meta.collect("act_123", "2026-01-01", "2026-01-02", "token", lambda request: Response({"data": [{"ad_id": "1"}], "paging": {"next": "ignored"}}))
        self.assertFalse(result["coverage"]["complete"])
        self.assertIn("additional pages not collected", result["coverage"]["omissions"])

    def test_dry_run_makes_no_network_call(self):
        completed = subprocess.run([sys.executable, str(SCRIPTS / "marketing-account-snapshot-helper.py"), "collect", "--provider", "meta", "--account-ref", "act_123", "--from", "2026-01-01", "--to", "2026-01-02", "--dry-run"], text=True, capture_output=True, check=True)  # nosec B603 -- fixed local test helper and arguments
        self.assertEqual(json.loads(completed.stdout)["network_calls"], 0)

    def test_invalid_account_refs_are_rejected(self):
        with self.assertRaises(google.GoogleAccountError): google.collect("bad", "2026-01-01", "2026-01-02", "x", "y")
        with self.assertRaises(meta.MetaAccountError): meta.collect("bad", "2026-01-01", "2026-01-02", "x")


if __name__ == "__main__":
    unittest.main()
