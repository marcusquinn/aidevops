#!/usr/bin/env python3
"""Focused tests for getanyapi-helper.py."""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

import getanyapi_evidence as EVIDENCE  # noqa: E402
import getanyapi_client as CLIENT  # noqa: E402

HELPER = SCRIPTS_DIR / "getanyapi-helper.py"
SPEC = importlib.util.spec_from_file_location("getanyapi_helper", HELPER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GetAnyAPIHelperTests(unittest.TestCase):
    def test_price_ceiling_uses_published_failover_maximum(self) -> None:
        detail = {"pricing": {"failoverMaxUsd": 0.0123, "from": {"maxUsd": 0.001}}}
        self.assertEqual(MODULE.price_ceiling(detail), Decimal("0.0123"))

    def test_native_path_rejects_private_absolute_paths(self) -> None:
        with self.assertRaises(MODULE.AnyAPIError):
            MODULE.safe_native_path("/Users/example/private-agent.md")
        self.assertEqual(
            MODULE.safe_native_path("tools/data-extraction/outscraper.md"),
            "tools/data-extraction/outscraper.md",
        )

    def test_input_file_must_be_owner_only(self) -> None:
        if os.name != "posix":
            self.skipTest("POSIX permission bits are not available")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            path.write_text('{"query":"public data"}', encoding="utf-8")
            path.chmod(0o644)
            with self.assertRaises(MODULE.AnyAPIError):
                MODULE.read_input(str(path))
            path.chmod(0o600)
            self.assertEqual(MODULE.read_input(str(path)), {"query": "public data"})

    def test_evidence_is_content_free_and_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            previous = os.environ.get("AIDEVOPS_WORKSPACE_DIR")
            os.environ["AIDEVOPS_WORKSPACE_DIR"] = directory
            try:
                MODULE.append_evidence(
                    {
                        "sku": "reddit.search",
                        "category": "social",
                        "outcome": "success",
                        "request_id": "req_1",
                        "charged_cost_usd": "0.001",
                        "observed_cost_usd": "0.001",
                        "items": 10,
                        "native_status": "partial",
                        "native_path": "tools/data-extraction/outscraper.md",
                        "payload": {"query": "must not persist"},
                        "output": {"secret": "must not persist"},
                    }
                )
                path = EVIDENCE.ledger_path()
                event = json.loads(path.read_text(encoding="utf-8"))
                self.assertNotIn("payload", event)
                self.assertNotIn("output", event)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                if previous is None:
                    os.environ.pop("AIDEVOPS_WORKSPACE_DIR", None)
                else:
                    os.environ["AIDEVOPS_WORKSPACE_DIR"] = previous

    def test_evidence_rejects_symlink_target(self) -> None:
        if os.name != "posix":
            self.skipTest("symlink protection is verified on POSIX")
        with tempfile.TemporaryDirectory() as directory:
            previous = os.environ.get("AIDEVOPS_WORKSPACE_DIR")
            os.environ["AIDEVOPS_WORKSPACE_DIR"] = directory
            try:
                path = EVIDENCE.ledger_path()
                path.parent.mkdir(parents=True)
                target = Path(directory) / "target.jsonl"
                target.write_text("", encoding="utf-8")
                path.symlink_to(target)
                with self.assertRaises(MODULE.AnyAPIError):
                    MODULE.append_evidence({"sku": "example.lookup"})
            finally:
                if previous is None:
                    os.environ.pop("AIDEVOPS_WORKSPACE_DIR", None)
                else:
                    os.environ["AIDEVOPS_WORKSPACE_DIR"] = previous

    def test_study_deduplicates_request_updates_and_ranks_charge(self) -> None:
        events = [
            {
                "schema_version": 1,
                "sku": "reddit.search",
                "outcome": "pending",
                "request_id": "req_1",
                "charged_cost_usd": "0",
                "native_status": "partial",
                "native_path": "tools/data-extraction/outscraper.md",
            },
            {
                "schema_version": 1,
                "sku": "reddit.search",
                "outcome": "success",
                "request_id": "req_1",
                "charged_cost_usd": "0.01",
                "items": 20,
                "native_status": "partial",
                "native_path": "tools/data-extraction/outscraper.md",
            },
            {
                "schema_version": 1,
                "sku": "github.repository",
                "outcome": "success",
                "request_id": "req_2",
                "charged_cost_usd": "0.001",
                "items": 1,
                "native_status": "direct",
                "native_path": "tools/git/github-cli.md",
            },
            {
                "schema_version": 1,
                "sku": "reddit.search",
                "outcome": "error",
                "charged_cost_usd": "0.005",
                "native_status": "partial",
                "native_path": "tools/data-extraction/outscraper.md",
            },
        ]
        study = MODULE.build_study(events)
        self.assertEqual(study["terminal_uses"], 3)
        self.assertEqual(study["charged_usd"], "0.016")
        self.assertEqual(study["candidates"][0]["sku"], "reddit.search")
        self.assertEqual(study["candidates"][0]["attempts"], 2)

    def test_http_error_suppresses_response_body(self) -> None:
        error = urllib.error.HTTPError(
            "https://api.getanyapi.com/v1/run/example",
            400,
            "Bad Request",
            {},
            io.BytesIO(b'{"error":"echoed secret must not leak"}'),
        )
        with patch.object(CLIENT.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(MODULE.AnyAPIError) as caught:
                CLIENT.api_request(
                    "GET",
                    "/v1/run/example",
                    MODULE.RequestOptions(key="test-key"),
                )
        self.assertNotIn("echoed secret", str(caught.exception))

    def test_run_stops_before_payload_when_balance_is_below_ceiling(self) -> None:
        args = argparse.Namespace(
            sku="example.lookup",
            native_path="",
            approved_max_usd="1.00",
            input_file="-",
            fields=None,
            max_items=None,
            summary=False,
            timeout=120,
            native_status="missing",
        )
        with (
            patch.object(MODULE, "require_api_key", return_value="test-key"),
            patch.object(
                MODULE,
                "get_detail",
                return_value={"pricing": {"failoverMaxUsd": "0.50"}},
            ),
            patch.object(MODULE, "wallet_balance", return_value=Decimal("0.49")),
            patch.object(MODULE, "read_input") as read_input,
        ):
            with self.assertRaises(MODULE.AnyAPIError):
                MODULE.command_run(args)
        read_input.assert_not_called()

    def test_run_uses_idempotency_and_records_confirmed_charge(self) -> None:
        args = argparse.Namespace(
            sku="example.lookup",
            native_path="tools/data-extraction/outscraper.md",
            approved_max_usd="0.02",
            input_file="private.json",
            fields=None,
            max_items=None,
            summary=False,
            timeout=120,
            native_status="partial",
        )
        with (
            patch.object(MODULE, "require_api_key", return_value="test-key"),
            patch.object(
                MODULE,
                "get_detail",
                return_value={
                    "category": "data",
                    "pricing": {"failoverMaxUsd": "0.01"},
                },
            ),
            patch.object(MODULE, "wallet_balance", return_value=Decimal("1.00")),
            patch.object(MODULE, "read_input", return_value={"query": "public"}),
            patch.object(
                MODULE,
                "api_request",
                return_value=(
                    200,
                    {"costUsd": "0.008", "items": 3},
                    {"x-anyapi-request-id": "req_1"},
                ),
            ) as api_request,
            patch.object(MODULE, "append_evidence") as append_evidence,
            patch.object(MODULE, "emit_json"),
        ):
            MODULE.command_run(args)
        call = api_request.call_args
        self.assertEqual(call.args[:2], ("POST", "/v1/run/example.lookup"))
        self.assertTrue(call.args[2].headers["Idempotency-Key"])
        event = append_evidence.call_args.args[0]
        self.assertEqual(event["charged_cost_usd"], "0.008")
        self.assertEqual(event["request_id"], "req_1")


if __name__ == "__main__":
    unittest.main()
