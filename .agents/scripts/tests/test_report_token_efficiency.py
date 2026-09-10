#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused stdlib regression checks; no provider calls or production writes."""
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from report_token_efficiency import collect_efficiency, lineage_roots  # noqa: E402


class EfficiencyTests(unittest.TestCase):
    def test_repricing_reasoning_lineage_and_unknowns(self):
        pricing = {"version": "test", "models": {"known": {"input": 2, "output": 10, "cache_read": 0.2, "cache_write": 2.5}}}
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "requests.db"
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE llm_requests (timestamp TEXT, session_id TEXT, parent_session_id TEXT, model_id TEXT, variant TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL, pricing_version TEXT, routing_attempt INTEGER)")
                conn.executemany("INSERT INTO llm_requests VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                    ("2026-01-01T00:00:00Z", "child", "root", "known", "medium", 0, 0, 0, 0, 0, 0, "old", None),
                    ("2026-02-01T00:00:00Z", "root", None, "known", "medium", 100, 20, 30, 900, 0, 9, "old", 1),
                    ("2026-02-02T00:00:00Z", "child", None, "known", "medium", 300, 0, 0, 100, 0, 5, "new", 2),
                    ("2026-02-03T00:00:00Z", "other", None, "known-pro", "high", 100, 0, 0, 0, 0, None, None, None),
                ])
            before = db.read_bytes()
            result = collect_efficiency(db, pricing, "2026-02-01T00:00:00Z")
            self.assertEqual(db.read_bytes(), before)
            self.assertEqual(result["summary"]["requests"], 3)
            self.assertEqual(result["summary"]["tokens_reasoning"], 30)
            self.assertIsNone(result["summary"]["repriced_api_equivalent_usd"])
            self.assertEqual(result["summary"]["priced_requests"], 2)
            self.assertEqual(result["summary"]["retry_observed_pct"], 50)
            self.assertIsNone(result["summary"]["escalation_observed_pct"])
            known = next(row for row in result["models"] if row["model"] == "known")
            self.assertEqual(known["repriced_api_equivalent_usd"], 0.0015)
            self.assertEqual(known["recorded_cost_usd"], 14)
            self.assertEqual(known["median_prompt_tokens"], 700)
            self.assertEqual(known["p95_prompt_tokens"], 1000)
            self.assertEqual(result["session_family_count"], 2)
            self.assertEqual(result["largest_session_families"][0]["observed_child_sessions"], 1)
            self.assertIsNone(result["verified_completion_rate"])
            self.assertNotIn('"session_id"', json.dumps(result))

    def test_lineage_conflicts_and_cycles_are_not_guessed(self):
        roots, ambiguous = lineage_roots({"a": {"b"}, "b": {"a"}, "c": {"x", "y"}, "d": {"root"}})
        self.assertEqual(ambiguous, 3)
        self.assertEqual(roots, {"a": "a", "b": "b", "c": "c", "d": "root"})

    def test_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "absent.db"
            with self.assertRaises(sqlite3.OperationalError):
                collect_efficiency(db, {}, "2026-01-01")
            self.assertFalse(db.exists())

    def test_empty_old_schema_has_explicit_unavailable_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "empty.db"
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE llm_requests (timestamp TEXT, session_id TEXT, model_id TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER)")
            result = collect_efficiency(db, {}, "2026-01-01")
            self.assertEqual(result["models"], [])
            self.assertIsNone(result["summary"]["cache_token_hit_pct"])
            self.assertIsNone(result["summary"]["recorded_cost_usd"])

    def test_objective_evidence_counts_failed_work_once_and_excludes_shared_work(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "objectives.db"
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE llm_requests (id TEXT, timestamp TEXT, session_id TEXT, model_id TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL)")
                conn.execute("CREATE TABLE runtime_events (id INTEGER, occurred_at TEXT, event_type TEXT, payload_json TEXT)")
                conn.executemany("INSERT INTO llm_requests VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [("a", "2026-02-01", "one", "model", 10, 2, 0, 0, 0, 1), ("b", "2026-02-01", "two", "model", 20, 3, 0, 0, 0, 2)])
                events = [(1, "2026-02-01", "objective.outcome", {"objective_id": "one", "outcome": "verified"}), (2, "2026-02-01", "objective.outcome", {"objective_id": "two", "outcome": "failed"}), (3, "2026-02-01", "objective.session.attached", {"objective_id": "one", "allocation": "unique", "request_ids": ["a"]}), (4, "2026-02-01", "objective.session.attached", {"objective_id": "two", "allocation": "unique", "request_ids": ["b"]}), (5, "2026-02-01", "objective.session.attached", {"objective_id": "one", "allocation": "unallocated", "request_ids": ["shared"]})]
                conn.executemany("INSERT INTO runtime_events VALUES (?, ?, ?, ?)", [(event_id, occurred_at, event_type, json.dumps(payload)) for event_id, occurred_at, event_type, payload in events])
            evidence = collect_efficiency(db, {}, "2026-01-01")["objective_evidence"]
            self.assertEqual(evidence["verified_objective_count"], 1)
            self.assertEqual(evidence["attributable_request_count"], 2)
            self.assertEqual(evidence["attributable_cost_usd"], 3)
            self.assertEqual(evidence["cost_per_verified_objective_usd"], 3)
            self.assertEqual(evidence["coverage"]["unallocated_attachments"], 1)


if __name__ == "__main__":
    unittest.main()
