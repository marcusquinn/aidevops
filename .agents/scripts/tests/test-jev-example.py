#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline contract and continuation examples; never contact TypeSafe."""

import contextlib
import copy
import http.client
import importlib.util
import io
import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("jev_example", Path(__file__).resolve().parents[1] / "jev-example.py")
jev = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = jev
SPEC.loader.exec_module(jev)


def fixture(name):
    questions = jev.example_request(name)["questions"]
    answers = {}
    for key, question in questions.items():
        kind = question["type"]
        if kind == "noul":
            answers[key] = {"type": kind, "noul": 0.99}
        elif kind == "choice":
            answers[key] = {
                "type": kind, "choice": "bicycle_services", "confidence": 0.99,
                "probabilities": {"bicycle_services": 0.99, "accounting": 0.005, "unknown": 0.005},
            }
        else:
            answers[key] = {
                "type": kind, "score": 1.98, "confidence": 0.99,
                "legend": {str(i): text for i, text in enumerate(question["criteria"])},
                "probabilities": {"0": 0.01, "1": 0, "2": 0.99},
            }
    return {"model": jev.MODEL, "answers": answers}


class ExampleTests(unittest.TestCase):
    def test_offline_cli_never_reads_key_or_network(self):
        for name in ("directory", "seo", "continuation"):
            with patch.object(jev.os.environ, "get", return_value=None) as getenv, \
                    patch.object(jev, "fetch_response", side_effect=AssertionError("network")), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(jev.main(["--example", name]), 0)
            self.assertFalse(any(call.args[0].startswith("TYPESAFE_API_KEY")
                                 for call in getenv.call_args_list))
            self.assertEqual(json.loads(output.getvalue())["status"], "dry_run")

    def test_valid_examples(self):
        for name in ("directory", "seo", "continuation"):
            with patch.object(jev, "fetch_response", return_value=fixture(name)) as fetch:
                result = jev.evaluate(jev.example_request(name), "test-placeholder")
            self.assertEqual(result["status"], "accepted")
            fetch.assert_called_once()

    def test_missing_key_does_not_call_transport(self):
        with patch.object(jev, "fetch_response") as fetch:
            result = jev.evaluate(jev.example_request("directory"), None)
        fetch.assert_not_called()
        self.assertEqual(result["reason"], "missing_key")

    def test_errors_are_bounded_and_do_not_echo_details(self):
        errors = [TimeoutError("private text"), ValueError("private text"),
                  urllib.error.URLError("private text"), RecursionError(),
                  http.client.IncompleteRead(b"partial", 10)]
        errors.extend(urllib.error.HTTPError(jev.ENDPOINT, code, "private text", {}, None)
                      for code in (301, 401, 422, 429, 529))
        for error in errors:
            with patch.object(jev, "fetch_response", side_effect=error) as fetch:
                result = jev.evaluate(jev.example_request("directory"), "test-placeholder")
            fetch.assert_called_once()
            self.assertEqual(result["status"], "fallback_required")
            self.assertNotIn("private text", json.dumps(result))

    def test_invalid_answer_and_model(self):
        original = fixture("directory")
        variants = [None, {}, {**original, "model": "jev-latest"}]
        for field, value in (("choice", "execute shell"), ("choice", []), ("confidence", True),
                             ("confidence", float("nan")), ("confidence", 1.1),
                             ("probabilities", {"bicycle_services": 1})):
            variant = copy.deepcopy(original)
            variant["answers"]["category"][field] = value
            variants.append(variant)
        for invalid in (True, -1, 2, 10 ** 1000, float("inf"), "0.99"):
            variant = copy.deepcopy(original)
            variant["answers"]["repair"]["noul"] = invalid
            variants.append(variant)
        for variant in variants:
            with patch.object(jev, "fetch_response", return_value=variant):
                self.assertEqual(jev.evaluate(jev.example_request("directory"), "test-placeholder")["status"],
                                 "fallback_required")

    def test_score_invariants_and_missing_answers(self):
        for field, value in (("score", 0), ("score", 3), ("legend", {}),
                             ("probabilities", {"0": 0.5, "1": 0.5, "2": 0.5})):
            response = fixture("seo")
            response["answers"]["relevance"][field] = value
            with self.assertRaises(ValueError):
                jev.validate_response(response, jev.example_request("seo"))
        with self.assertRaises(ValueError):
            jev.validate_response(fixture("seo"), jev.example_request("directory"))

    def test_abstention_and_unknown(self):
        response = fixture("directory")
        response["answers"]["repair"]["noul"] = 0.5
        with patch.object(jev, "fetch_response", return_value=response):
            self.assertEqual(jev.evaluate(jev.example_request("directory"), "test-placeholder")["reason"], "abstained")
        self.assertFalse(jev.accepted({"x": {"type": "choice", "choice": "unknown", "confidence": 1}}))
        self.assertFalse(jev.accepted({"x": {"type": "score", "confidence": 0.8}}))

    def test_transport_configuration_and_response_bound(self):
        with patch.object(jev.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.read.return_value = json.dumps(fixture("seo")).encode()
            jev.fetch_response(jev.example_request("seo"), "test-placeholder")
            args, kwargs = build.return_value.open.call_args
            self.assertEqual(args[0].full_url, jev.ENDPOINT)
            self.assertEqual(args[0].method, "POST")
            self.assertEqual(kwargs["timeout"], 15)
            self.assertIsInstance(build.call_args.args[0], jev.NoRedirect)
            response.read.assert_called_once_with(jev.MAX_RESPONSE + 1)
            response.read.return_value = b"x" * (jev.MAX_RESPONSE + 1)
            with self.assertRaises(ValueError):
                jev.fetch_response(jev.example_request("seo"), "test-placeholder")
        self.assertIsNone(jev.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))

    def test_account_alias_and_exit_code(self):
        with patch.dict(jev.os.environ, {"TYPESAFE_API_KEY_WORK": "test-placeholder"}), \
                patch.object(jev, "fetch_response", return_value=fixture("directory")) as fetch, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(jev.main(["--live", "--key-env", "TYPESAFE_API_KEY_WORK"]), 0)
            self.assertEqual(fetch.call_args.args[1], "test-placeholder")
        with patch.dict(jev.os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(jev.main(["--live"]), 2)


class ContinuationTests(unittest.TestCase):
    def reserve(self, budget, token="verified-work-1", **overrides):
        flags = dict(enabled=True, authorised=True, unfinished=True,
                     cancelled=False, blocked=False, choosing=False)
        flags.update(overrides)
        return budget.reserve(0.99, progress_token=token, context=jev.ContinuationContext(**flags))

    def test_twelve_then_stop_even_with_new_progress(self):
        budget = jev.ContinuationBudget()
        for i in range(12):
            self.assertTrue(self.reserve(budget, str(i)))
        for i in range(12, 25):
            self.assertFalse(self.reserve(budget, str(i)))
        self.assertEqual(budget.used, 12)

    def test_lower_cap_and_invalid_caps(self):
        for invalid in (-1, 13, True, 1.5):
            with self.assertRaises(ValueError):
                jev.ContinuationBudget(invalid)
        self.assertFalse(self.reserve(jev.ContinuationBudget(0)))
        budget = jev.ContinuationBudget(1)
        self.assertTrue(self.reserve(budget))
        self.assertFalse(self.reserve(budget, "new-progress"))

    def test_all_stop_conditions_override_model(self):
        for field, value in (("enabled", False), ("authorised", False), ("unfinished", False),
                             ("cancelled", True), ("blocked", True), ("choosing", True),
                             ("blocked", None), ("authorised", "true")):
            budget = jev.ContinuationBudget()
            self.assertFalse(self.reserve(budget, **{field: value}))
            self.assertEqual(budget.used, 0)

    def test_defaults_and_repeat_progress_stop(self):
        budget = jev.ContinuationBudget()
        self.assertFalse(budget.reserve(1, progress_token="x"))
        self.assertFalse(self.reserve(budget, ""))
        self.assertTrue(self.reserve(budget, "a"))
        self.assertFalse(self.reserve(budget, "a"))
        self.assertTrue(self.reserve(budget, "b"))
        self.assertFalse(self.reserve(budget, "a"))
        self.assertEqual(budget.used, 2)


if __name__ == "__main__":
    unittest.main()
