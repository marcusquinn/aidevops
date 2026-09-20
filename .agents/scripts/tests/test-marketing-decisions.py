#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused offline tests for the shared marketing decision contract."""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
SPEC = importlib.util.spec_from_file_location("marketing_decision_cli", SCRIPTS / "marketing-decision-helper.py")
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)
contract = cli.contract


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.input = fixture("core-valid.json")
        self.request = contract.validate_input(self.input)
        self.decisions = fixture("core-decisions.json")

    def supplied(self, decisions: dict | None = None) -> dict:
        return contract.validate_supplied(decisions or self.decisions, self.request)

    def test_two_domain_batches_produce_valid_evidence_backed_report(self):
        report = contract.run(self.request, self.supplied())
        self.assertIs(contract.validate_report(report, self.request), report)
        self.assertEqual({row["domain"] for row in report["results"]}, {"ads", "seo"})
        self.assertEqual([row["status"] for row in report["results"]], ["accepted", "accepted"])
        self.assertTrue(all(row["source"]["source_id"] for row in report["results"]))
        self.assertIsNone(report["metrics"]["cost_usd"])
        self.assertEqual(report["metrics"]["cost_measurement"], "unknown")
        self.assertEqual(report["authority"], "non_mutating_recommendations_only")

    def test_malformed_inputs_and_unknown_versions_fail_closed(self):
        mutations = [
            ("schema", "aidevops.marketing-decision-input/v2"),
            ("request_id", "../../escape"),
            ("batches", []),
            ("extra", True),
        ]
        for key, value in mutations:
            candidate = copy.deepcopy(self.input)
            candidate[key] = value
            with self.subTest(key=key), self.assertRaises(contract.DecisionError):
                contract.validate_input(candidate)
        oversized = copy.deepcopy(self.input)
        oversized["limits"]["max_rows"] = contract.MAX_ROWS + 1
        with self.assertRaises(contract.DecisionError):
            contract.validate_input(oversized)
        fractional_budget = copy.deepcopy(self.input)
        fractional_budget["limits"]["budget"]["max_input_tokens"] = 1.5
        with self.assertRaises(contract.DecisionError):
            contract.validate_input(fractional_budget)

    def test_invalid_candidate_and_unsafe_action_are_retained_not_accepted(self):
        for field, value in [
            ("value", "candidate-not-observed"),
            ("action_proposal", {"kind": "execute", "candidate_ids": [], "non_mutating": False}),
        ]:
            decisions = copy.deepcopy(self.decisions)
            decisions["decisions"][0][field] = value
            report = contract.run(self.request, self.supplied(decisions))
            result = report["results"][0]
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["reason"], "invalid_decision")
            self.assertIn("ad-creative-row", report["checkpoint"]["remaining_row_ids"])

    def test_score_is_not_probability_and_unknown_cost_is_not_zero(self):
        request_data = copy.deepcopy(self.input)
        request_data["batches"][0]["rows"][0]["decision_kind"] = "score"
        request = contract.validate_input(request_data)
        decisions = copy.deepcopy(self.decisions)
        decisions["input_digest"] = request.input_digest
        decisions["decisions"][0].update(kind="score", value=4.2, probability=0.5)
        supplied = contract.validate_supplied(decisions, request)
        report = contract.run(request, supplied)
        self.assertEqual(report["results"][0]["status"], "failed")
        self.assertIsNone(report["metrics"]["cost_usd"])

    def test_budget_and_cancellation_checkpoint_remaining_rows(self):
        request_data = copy.deepcopy(self.input)
        request_data["limits"]["budget"]["max_input_tokens"] = 100
        request = contract.validate_input(request_data)
        decisions = copy.deepcopy(self.decisions)
        decisions["input_digest"] = request.input_digest
        supplied = contract.validate_supplied(decisions, request)
        report = contract.run(request, supplied)
        self.assertEqual(report["results"][0]["reason"], "budget_exceeded")
        self.assertEqual(report["checkpoint"]["accepted"], 0)
        self.assertEqual(report["metrics"]["input_tokens"], 180)
        self.assertIsNone(report["metrics"]["cost_usd"])

        decisions = copy.deepcopy(self.decisions)
        decisions["cancelled_after_row_id"] = "ad-creative-row"
        report = contract.run(self.request, self.supplied(decisions))
        self.assertEqual(report["results"][1]["reason"], "cancelled")
        report["status"] = "complete"
        with self.assertRaises(contract.DecisionError):
            contract.validate_report(report, self.request)

    def test_exceeded_budget_latches_for_following_rows(self):
        request_data = copy.deepcopy(self.input)
        request_data["limits"]["budget"]["max_input_tokens"] = 200
        request_data["batches"][1]["rows"].append({
            "row_id": "following-row",
            "source": {"source_id": "search-console-10", "span": "queries-25-26"},
            "decision_kind": "choice",
            "candidates": ["page-support"],
        })
        request = contract.validate_input(request_data)
        decisions = copy.deepcopy(self.decisions)
        decisions["input_digest"] = request.input_digest
        decisions["decisions"].append({
            "row_id": "following-row", "kind": "choice", "value": "page-support",
            "probability": 0.8, "confidence": 0.8,
            "calibration": {"provenance": "reported", "reference": None},
            "abstention_reason": None, "action_proposal": None,
            "usage": {"latency_ms": 1, "input_tokens": 1, "output_tokens": 1, "cost_usd": None},
        })
        report = contract.run(request, contract.validate_supplied(decisions, request))
        self.assertEqual([row["status"] for row in report["results"]], ["accepted", "deferred", "deferred"])
        self.assertEqual(report["results"][2]["reason"], "budget_exceeded")

    def test_cache_is_scope_window_and_model_aware(self):
        base = self.request.cache_key
        for mutation in ("account", "window", "model"):
            data = copy.deepcopy(self.input)
            if mutation == "account":
                data["scope"]["account_id"] = "account-east"
            elif mutation == "window":
                data["performance_window"]["start"] = "2026-09-02T00:00:00Z"
            else:
                data["model"]["version"] = "2"
            self.assertNotEqual(contract.validate_input(data).cache_key, base)


class StorageAndCLITests(unittest.TestCase):
    def setUp(self):
        temp_root = Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
        temp_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="marketing-decisions-", dir=temp_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input_path = self.root / "input.json"
        self.decisions_path = self.root / "decisions.json"
        self.input_path.write_text(json.dumps(fixture("core-valid.json")), encoding="utf-8")
        self.decisions_path.write_text(json.dumps(fixture("core-decisions.json")), encoding="utf-8")

    def invoke(self, *args: str) -> tuple[int, dict]:
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = cli.main(list(args))
        return code, json.loads(output.getvalue())

    def test_real_cli_validate_and_offline_run_never_use_network(self):
        with patch("socket.create_connection", side_effect=AssertionError("network")):
            code, valid = self.invoke("validate", "--input", str(self.input_path))
            self.assertEqual(code, 0)
            self.assertEqual(valid["rows"], 2)
            code, report = self.invoke(
                "run", "--input", str(self.input_path), "--decisions", str(self.decisions_path), "--dry-run"
            )
            store = self.root / "private-cli"
            stored_code, stored_report = self.invoke(
                "run", "--input", str(self.input_path), "--decisions", str(self.decisions_path),
                "--dry-run", "--store", str(store),
            )
        self.assertEqual(code, 0)
        self.assertEqual(report["checkpoint"]["accepted"], 2)
        self.assertEqual(stored_code, 0)
        request = contract.validate_input(fixture("core-valid.json"))
        self.assertEqual(contract.validate_report(stored_report, request), stored_report)
        self.assertEqual(set(self.root.iterdir()), {self.input_path, self.decisions_path, store})

    def test_atomic_replay_conflict_and_account_isolation(self):
        request = contract.validate_input(fixture("core-valid.json"))
        supplied = contract.validate_supplied(fixture("core-decisions.json"), request)
        report = contract.run(request, supplied)
        store = self.root / "private"
        path, replayed = contract.store_report(store, request, report)
        self.assertFalse(replayed)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertTrue(contract.store_report(store, request, report)[1])

        conflict_data = fixture("core-valid.json")
        conflict_data["batches"][0]["rows"][0]["candidates"].append("ad-variant-c")
        conflict = contract.validate_input(conflict_data)
        with self.assertRaises(contract.DecisionError):
            contract.store_report(store, conflict, {**report, "input_digest": conflict.input_digest, "cache_key": conflict.cache_key})

        other_data = fixture("core-valid.json")
        other_data["scope"]["account_id"] = "account-east"
        other = contract.validate_input(other_data)
        other_report = {**report, "scope": other.document["scope"], "input_digest": other.input_digest, "cache_key": other.cache_key}
        other_path, _ = contract.store_report(store, other, other_report)
        self.assertNotEqual(path.parent, other_path.parent)

    def test_storage_rejects_report_not_bound_to_request_before_writing(self):
        request = contract.validate_input(fixture("core-valid.json"))
        supplied = contract.validate_supplied(fixture("core-decisions.json"), request)
        report = contract.run(request, supplied)
        for field, value in [
            ("scope", {"project_id": "other", "account_id": "other"}),
            ("input_digest", "sha256:" + "0" * 64),
            ("cache_key", "sha256:" + "1" * 64),
        ]:
            store = self.root / f"rejected-{field}"
            altered = {**report, field: value}
            with self.subTest(field=field), self.assertRaises(contract.DecisionError):
                contract.store_report(store, request, altered)
            self.assertFalse(store.exists())

        store = self.root / "rejected-decision"
        altered = copy.deepcopy(report)
        altered["results"][0]["decision"]["value"] = "candidate-not-observed"
        with self.assertRaises(contract.DecisionError):
            contract.store_report(store, request, altered)
        self.assertFalse(store.exists())

    def test_concurrent_identical_replay_is_bounded(self):
        request = contract.validate_input(fixture("core-valid.json"))
        supplied = contract.validate_supplied(fixture("core-decisions.json"), request)
        report = contract.run(request, supplied)
        store = self.root / "concurrent"
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: contract.store_report(store, request, report), range(2)))
        self.assertEqual({path for path, _ in results}, {results[0][0]})
        self.assertEqual(sum(replayed for _, replayed in results), 1)

    def test_symlink_storage_and_malformed_cli_have_no_artifacts(self):
        outside = self.root / "outside"
        outside.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(outside, target_is_directory=True)
        code, _ = self.invoke(
            "run", "--input", str(self.input_path), "--decisions", str(self.decisions_path),
            "--dry-run", "--store", str(linked),
        )
        self.assertEqual(code, 2)
        self.assertEqual(list(outside.iterdir()), [])

        malformed = self.root / "malformed.json"
        malformed.write_text("{", encoding="utf-8")
        code, _ = self.invoke("validate", "--input", str(malformed))
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
