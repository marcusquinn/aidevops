#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Mocked contract tests for the opt-in Jev marketing adapter."""

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "marketing-decisions"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("marketing_decision_jev_helper", SCRIPTS / "marketing-decision-jev-helper.py")
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class JevAdapterTests(unittest.TestCase):
    def setUp(self):
        self.input_path = FIXTURES / "jev-request.json"
        self.request = cli.contract.validate_input(fixture("jev-request.json"))
        self.response = fixture("jev-response.json")

    def invoke(self, *args):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = cli.main(list(args))
        return code, json.loads(output.getvalue())

    def test_dry_run_never_uses_key_or_network(self):
        with patch.object(cli.jev, "fetch", side_effect=AssertionError("network")):
            code, result = self.invoke("decide", "--input", str(self.input_path), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(result["network"], "not_attempted")

    def test_mocked_mapping_preserves_choice_multilabel_and_provenance(self):
        with patch.object(cli.jev, "fetch", return_value=self.response):
            result = cli.jev.decide(self.request, "placeholder")
        self.assertEqual(result["status"], "complete")
        rows = result["report"]["results"]
        self.assertEqual(rows[0]["decision"]["value"], "b")
        self.assertEqual(rows[0]["decision"]["calibration"]["provenance"], "reported")
        self.assertEqual(rows[1]["decision"]["value"], ["x"])

    def test_invalid_response_and_model_drift_require_fallback(self):
        for response in ({}, {**self.response, "model": "jev-latest"}, {**self.response, "answers": {}}):
            with patch.object(cli.jev, "fetch", return_value=response):
                result = cli.jev.decide(self.request, "placeholder")
            self.assertEqual(result["status"], "fallback_required")
            self.assertFalse(result["fallback_ran"])

    def test_cooldown_and_missing_authority_do_not_send_requests(self):
        import urllib.error
        error = urllib.error.HTTPError(cli.jev.ENDPOINT, 429, "rate limited", {}, None)
        with patch.object(cli.jev, "fetch", side_effect=error):
            result = cli.jev.decide(self.request, "placeholder")
        self.assertEqual(result["reason"], "cooldown")
        with patch.object(cli.jev, "decide", side_effect=AssertionError("transport")):
            code, result = self.invoke("decide", "--input", str(self.input_path), "--live")
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "authorization_required")

    def test_budget_stop_is_explicit_fallback_required(self):
        constrained = fixture("jev-request.json")
        constrained["limits"]["budget"]["max_input_tokens"] = 1
        request = cli.contract.validate_input(constrained)
        with patch.object(cli.jev, "fetch", return_value=self.response):
            result = cli.jev.decide(request, "placeholder")
        self.assertEqual(result["status"], "fallback_required")
        self.assertEqual(result["reason"], "budget_or_unresolved")

    def test_confidential_data_is_blocked_before_transport(self):
        confidential = fixture("jev-request.json")
        confidential["data_classification"] = "confidential"
        with patch.object(cli.contract, "load_json", return_value=confidential), patch.object(cli.jev, "decide", side_effect=AssertionError("transport")):
            code, result = self.invoke("decide", "--input", str(self.input_path), "--live", "--provider-authorized", "--data-authorized")
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "privacy_block")


if __name__ == "__main__":
    unittest.main()
