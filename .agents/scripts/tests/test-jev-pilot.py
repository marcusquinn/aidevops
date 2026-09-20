#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline pilot contracts and normal CLI path; no external inference."""

import contextlib
import copy
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jev_pilot_cli", SCRIPTS / "jev-pilot.py")
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)
pilot = cli.pilot


def response(data, labels, confidence=1.0):
    answers = {}
    for index, label in enumerate(labels):
        answers[f"q{index}"] = {"type": "choice", "choice": label, "confidence": confidence,
                               "probabilities": {key: float(key == label) for key in pilot.LABELS[data["mode"]]}}
    return {"model": pilot.provider.MODEL, "answers": answers, "usage": {"input_tokens": 200}}


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.data = pilot.sample_corpus("retrieval")

    def test_corpus_validation_and_bounds(self):
        self.assertEqual(pilot.validate_corpus(self.data, "retrieval"), self.data)
        changes = [("data_classification", "private"), ("query", ""), ("items", []),
                   ("items", self.data["items"] * 5), ("extra", "not allowed")]
        for key, value in changes:
            data = copy.deepcopy(self.data)
            data[key] = value
            with self.assertRaises(ValueError):
                pilot.validate_corpus(data, "retrieval")
        for key, value in [("id", "../../private"), ("text", "x" * 4001), ("label", "bad")]:
            data = copy.deepcopy(self.data)
            data["items"][0][key] = value
            with self.assertRaises(ValueError):
                pilot.validate_corpus(data, "retrieval")

    def test_gold_ids_and_metadata_never_sent(self):
        request = pilot.make_request(self.data)
        self.assertEqual(set(request["state"]), {"items", "query"})
        self.assertEqual(request["state"]["items"], [row["text"] for row in self.data["items"]])
        self.assertNotIn('"label"', json.dumps(request))

    def test_retrieval_reversible_and_correct_metrics(self):
        original = copy.deepcopy(self.data)
        with patch.object(pilot.provider, "fetch_response", return_value=response(
                self.data, ["relevant", "irrelevant", "relevant"])) as fetch:
            report = pilot.run(self.data, "placeholder", live=True)
        fetch.assert_called_once()
        self.assertEqual(report["selection"]["selected_ids"], ["r1", "r3"])
        self.assertEqual(report["selection"]["deferred_ids"], ["r2"])
        self.assertEqual(report["metrics"]["relevant_deferred"], 0)
        self.assertEqual(self.data, original)
        self.assertNotIn(self.data["items"][0]["text"], json.dumps(report))
        with patch.object(pilot.provider, "fetch_response", side_effect=AssertionError("network")):
            restored = pilot.run(self.data, live=True, restore=True)
        self.assertEqual(restored["selection"]["selected_ids"], ["r1", "r2", "r3"])

    def test_uncertain_retained_and_empty_selection_restored(self):
        for labels, confidence in [(["unknown", "irrelevant", "relevant"], 1),
                                   (["irrelevant"] * 3, 0.8), (["irrelevant"] * 3, 1)]:
            with patch.object(pilot.provider, "fetch_response", return_value=response(self.data, labels, confidence)):
                result = pilot.run(self.data, "placeholder", live=True)["selection"]
            self.assertIn("r1", result["selected_ids"])
            self.assertIn("r1", result["fallback_ids"])

    def test_failure_no_key_and_bad_answer_preserve_all(self):
        with patch.object(pilot.provider, "fetch_response") as fetch:
            report = pilot.run(self.data, live=True)
        fetch.assert_not_called()
        self.assertEqual(report["status"], "fallback_required")
        for payload in ({}, {"model": "wrong"}, response(self.data, ["relevant"])):
            with patch.object(pilot.provider, "fetch_response", return_value=payload):
                report = pilot.run(self.data, "placeholder", live=True)
            self.assertEqual(report["selection"]["selected_ids"], ["r1", "r2", "r3"])

    def test_false_negative_is_measured_not_hidden(self):
        with patch.object(pilot.provider, "fetch_response", return_value=response(
                self.data, ["irrelevant", "irrelevant", "relevant"])):
            report = pilot.run(self.data, "placeholder", live=True)
        self.assertEqual(report["metrics"]["relevant_deferred"], 1)

    def test_triage_remains_shadow_and_all_items_retained(self):
        data = pilot.sample_corpus("triage")
        with patch.object(pilot.provider, "fetch_response", return_value=response(
                data, ["defect", "enhancement", "question"])):
            report = pilot.run(data, "placeholder", live=True)
        self.assertTrue(report["shadow_only"])
        self.assertEqual(report["selection"]["deferred_ids"], [])
        self.assertEqual(report["metrics"]["pilot_correct"], 3)
        self.assertEqual(report["selection"]["all_ids"], report["selection"]["selected_ids"])


class CLITests(unittest.TestCase):
    def setUp(self):
        root = Path.home() / ".aidevops/.agent-workspace/tmp"
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="jev-pilot-test-", dir=root)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        home_patch = patch.object(cli.Path, "home", return_value=self.home)
        home_patch.start()
        self.addCleanup(home_patch.stop)

    def invoke(self, *args):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = cli.main(list(args))
        return code, json.loads(output.getvalue())

    def test_offline_cli_private_report_and_no_metrics_stdout(self):
        with patch.object(pilot.provider, "fetch_response", side_effect=AssertionError("network")):
            code, summary = self.invoke("retrieval")
        self.assertEqual(code, 0)
        path = Path(summary["private_report"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertNotIn("metrics", summary)
        self.assertEqual(json.loads(path.read_text())["schema"], pilot.SCHEMA)

    def test_custom_upload_requires_consent(self):
        path = self.home / "corpus.json"
        path.write_text(json.dumps(pilot.sample_corpus("retrieval")))
        with patch.object(pilot.provider, "fetch_response") as fetch:
            code, _ = self.invoke("retrieval", "--input", str(path), "--live")
        fetch.assert_not_called()
        self.assertEqual(code, 2)

    def test_scan_failure_blocks_and_restore_never_calls(self):
        with patch.object(cli, "scan_request", return_value=False), \
                patch.object(pilot.provider, "fetch_response") as fetch:
            self.assertEqual(self.invoke("triage", "--live")[0], 2)
            self.assertEqual(self.invoke("triage", "--live", "--unfiltered")[0], 0)
        fetch.assert_not_called()

    def test_symlink_or_git_report_directory_blocked(self):
        (self.home / ".git").mkdir()
        with self.assertRaises(ValueError):
            cli.report_directory()
        (self.home / ".git").rmdir()
        (self.home / ".aidevops").symlink_to(self.home, target_is_directory=True)
        with self.assertRaises(OSError):
            cli.report_directory()

    def test_directory_swap_cannot_redirect_report(self):
        root = cli.report_directory()
        outside = self.home / "outside"
        outside.mkdir()
        original_open = cli.open_component

        def swap(parent_fd, name):
            if name == "jev-pilots":
                root.rename(root.with_name("saved"))
                root.symlink_to(outside, target_is_directory=True)
            return original_open(parent_fd, name)

        with patch.object(cli, "open_component", side_effect=swap):
            with self.assertRaises(OSError):
                cli.save_report({"test": True})
        self.assertEqual(list(outside.iterdir()), [])

    def test_alias_live_path_and_exclusive_output(self):
        data = pilot.sample_corpus("triage")
        with patch.object(cli, "scan_request", return_value=True), \
                patch.dict(os.environ, {"TYPESAFE_API_KEY_WORK": "placeholder"}), \
                patch.object(pilot.provider, "fetch_response", return_value=response(
                    data, ["defect", "enhancement", "question"])) as fetch:
            code, summary = self.invoke("triage", "--live", "--key-env", "TYPESAFE_API_KEY_WORK")
        self.assertEqual(code, 0)
        self.assertEqual(fetch.call_args.args[1], "placeholder")
        self.assertNotIn("placeholder", json.dumps(summary))
        with patch.object(cli.uuid, "uuid4") as random_id:
            random_id.return_value.hex = "same"
            cli.save_report({"test": True})
            with self.assertRaises(FileExistsError):
                cli.save_report({"test": False})


if __name__ == "__main__":
    unittest.main()
