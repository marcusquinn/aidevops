#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fake-transport contract tests for approval-bound Google Ads account actions."""

from __future__ import annotations

import copy
import io
import json
import os
import re
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import google_ads_actions as ads  # noqa: E402
import marketing_action_approval as records  # noqa: E402

CUSTOMER = "1234567890"


class FakeAds:
    """In-memory account answering the adapter's fixed GAQL reads and mutate operations."""

    def __init__(self) -> None:
        self.campaigns = {"111": {"bidding": "MANUAL_CPC", "ecpc": False, "ceiling": None, "budget": "999"}}
        self.budgets = {"999": {"amount": "5000000", "shared": False}}
        self.negatives: list[dict] = []
        self.keywords = {"222~333": "ENABLED"}
        self.mutations: list[tuple[bool, list]] = []
        self.counter = 0

    def search(self, customer: str, query: str) -> list[dict]:
        if match := re.search(r"FROM (campaign|ad_group)_criterion WHERE \w+\.id = (\d+) AND", query):
            key = "campaignCriterion" if match[1] == "campaign" else "adGroupCriterion"
            return [{key: {"resourceName": item["rn"], "keyword": {"text": item["text"], "matchType": item["match"]}}}
                    for item in self.negatives if (item["level"], item["parent"]) == (match[1], match[2])]
        if match := re.search(r"adGroupCriteria/(\d+~\d+)'", query):
            status = self.keywords.get(match[1])
            keyword = {"text": "running shoes", "matchType": "EXACT"}
            return [{"adGroupCriterion": {"status": status, "negative": False, "keyword": keyword}}] if status else []
        match = re.search(r"FROM campaign WHERE campaign\.id = (\d+)", query)
        campaign = self.campaigns.get(match[1]) if match else None
        if not campaign:
            return []
        budget = self.budgets[campaign["budget"]]
        details = {"resourceName": f"customers/{customer}/campaigns/{match[1]}", "biddingStrategyType": campaign["bidding"]}
        if campaign["bidding"] == "MANUAL_CPC":
            details["manualCpc"] = {"enhancedCpcEnabled": campaign["ecpc"]}
        elif campaign["ceiling"]:
            details["targetSpend"] = {"cpcBidCeilingMicros": campaign["ceiling"]}
        return [{"campaign": details, "campaignBudget": {
            "resourceName": f"customers/{customer}/campaignBudgets/{campaign['budget']}",
            "amountMicros": budget["amount"], "explicitlyShared": budget["shared"]}}]

    def mutate(self, customer: str, operations: list, validate_only: bool) -> list:
        self.mutations.append((validate_only, copy.deepcopy(operations)))
        return [] if validate_only else [self._apply(customer, op) for op in operations]

    def _apply(self, customer: str, operation: dict) -> dict:
        (kind, body), = operation.items()
        result = kind.replace("Operation", "Result")
        if "create" in body:
            self.counter += 1
            level = "campaign" if kind.startswith("campaign") else "ad_group"
            parent = (body["create"].get("campaign") or body["create"]["adGroup"]).rsplit("/", 1)[1]
            path = "campaignCriteria" if level == "campaign" else "adGroupCriteria"
            name = f"customers/{customer}/{path}/{parent}~{9000 + self.counter}"
            keyword = body["create"]["keyword"]
            self.negatives.append({"level": level, "parent": parent, "text": keyword["text"],
                                   "match": keyword["matchType"], "rn": name})
            return {result: {"resourceName": name}}
        if "remove" in body:
            self.negatives = [item for item in self.negatives if item["rn"] != body["remove"]]
            return {result: {"resourceName": body["remove"]}}
        update, ident = body["update"], body["update"]["resourceName"].rsplit("/", 1)[1]
        if kind == "adGroupCriterionOperation":
            self.keywords[ident] = update["status"]
        elif kind == "campaignBudgetOperation":
            self.budgets[ident]["amount"] = update["amountMicros"]
        elif "targetSpend" in update:
            self.campaigns[ident].update(bidding="TARGET_SPEND", ceiling=update["targetSpend"].get("cpcBidCeilingMicros"))
        else:
            self.campaigns[ident].update(bidding="MANUAL_CPC", ecpc=update["manualCpc"]["enhancedCpcEnabled"], ceiling=None)
        return {result: {"resourceName": update["resourceName"]}}

    def writes(self) -> list:
        return [operations for validate_only, operations in self.mutations if not validate_only]


class GoogleAdsActionTests(unittest.TestCase):
    def setUp(self) -> None:
        workspace = Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
        workspace.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="google-ads-actions-", dir=workspace)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipts = self.root / "receipts"
        home = self.root / "home"
        (home / ".aidevops").mkdir(parents=True)
        for patcher in (patch.object(records, "_home", return_value=home),
                        patch.object(records, "TRUSTED_APPROVAL_UID", os.getuid())):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.account = FakeAds()
        self.config = {"schema": ads.CONFIG_SCHEMA, "customer_allowlist": ["123-456-7890"],
                       "max_daily_budget_micros": 20_000_000, "max_cpc_bid_ceiling_micros": 3_000_000,
                       "max_operations": 10}
        self.input = {"schema": ads.INPUT_SCHEMA, "customer_id": CUSTOMER, "owner": "current",
                      "source_evidence": ["google_ads_triage:test"], "actions": [
                          {"id": "neg", "kind": "campaign_negative_keyword", "campaign_id": "111",
                           "text": "free shoes", "match_type": "PHRASE"},
                          {"id": "pause", "kind": "keyword_status", "ad_group_id": "222", "criterion_id": "333",
                           "status": "PAUSED"},
                          {"id": "bid", "kind": "maximize_clicks", "campaign_id": "111",
                           "cpc_bid_ceiling_micros": 1_500_000},
                          {"id": "budget", "kind": "campaign_budget", "campaign_id": "111", "amount_micros": 8_000_000},
                      ]}

    def approve(self, subject: dict, operation: str = "apply", receipt: dict | None = None, **changes) -> None:
        nonce = f"nonce{operation}"
        cancellation = self.root / nonce
        cancellation.write_text(f"active:{nonce}\n", encoding="utf-8")
        cancellation.chmod(0o600)
        record = records.build_record(subject, operation, ads.PLAN_SCHEMA, nonce=nonce, cancellation_path=str(cancellation),
                                      receipt_digest=ads.action_io.digest(receipt) if receipt else None)
        record.update(changes)
        records.store_record(record)

    def plan(self) -> dict:
        return ads.build_plan(copy.deepcopy(self.input), self.config, self.account)

    def assert_no_write(self, plan: dict, error: type = ads.GoogleAdsActionError) -> None:
        with self.assertRaises(error):
            ads.apply_plan(plan, self.receipts, self.account)
        self.assertEqual(self.account.writes(), [])

    def test_plan_is_validate_only_and_records_state_and_inverses(self) -> None:
        plan = self.plan()
        self.assertEqual(self.account.mutations, [(True, plan["operations"])])
        self.assertEqual(self.account.campaigns["111"]["bidding"], "MANUAL_CPC")
        negative, pause, bid, budget = plan["actions"]
        self.assertEqual(negative["forward"]["campaignCriterionOperation"]["create"]["keyword"]["text"], "free shoes")
        self.assertEqual(pause["inverse"]["adGroupCriterionOperation"]["update"]["status"], "ENABLED")
        self.assertEqual(bid["before"], {"bidding_strategy_type": "MANUAL_CPC", "portfolio": False,
                                         "enhanced_cpc_enabled": False})
        self.assertEqual(budget["inverse"]["campaignBudgetOperation"]["update"]["amountMicros"], "5000000")
        self.assertEqual(ads.validate_plan(copy.deepcopy(plan)), plan)
        summary = records._plan_subject(plan)[2]
        self.assertIn("- APPLY neg [campaign_negative_keyword] add PHRASE negative \"free shoes\" to campaign 111",
                      summary)
        self.assertIn(f"    operation: {json.dumps(negative['forward'], sort_keys=True)}", summary)
        self.assertEqual((pause["before"]["text"], pause["after"]), ("running shoes", {**pause["before"], "status": "PAUSED"}))
        self.assertIn(f"keyword {pause['target']} \"running shoes\" [EXACT]: ENABLED -> PAUSED", pause["summary"])

    def test_plan_refuses_unlisted_customer_caps_and_existing_negative(self) -> None:
        for change in ({"customer_id": "999"},):
            with self.assertRaises(ads.GoogleAdsActionError):
                ads.build_plan({**copy.deepcopy(self.input), **change}, self.config, self.account)
        for index, field, value in ((2, "cpc_bid_ceiling_micros", 3_000_001), (3, "amount_micros", 20_000_001)):
            proposal = copy.deepcopy(self.input)
            proposal["actions"][index][field] = value
            with self.assertRaises(ads.GoogleAdsActionError):
                ads.build_plan(proposal, self.config, self.account)
        self.account.negatives.append({"level": "campaign", "parent": "111", "text": "Free Shoes", "match": "PHRASE",
                                       "rn": f"customers/{CUSTOMER}/campaignCriteria/111~1"})
        with self.assertRaises(ads.GoogleAdsActionError):
            self.plan()
        self.assertEqual(self.account.mutations, [])

    def test_apply_writes_once_with_receipt_audit_and_replay_noop(self) -> None:
        plan = self.plan()
        self.approve(plan)
        receipt, replayed = ads.apply_plan(plan, self.receipts, self.account)
        self.assertFalse(replayed)
        self.assertEqual(self.account.writes(), [plan["operations"]])
        self.assertEqual(receipt["status"], "applied")
        self.assertEqual((self.account.campaigns["111"]["bidding"], self.account.keywords["222~333"]),
                         ("TARGET_SPEND", "PAUSED"))
        self.assertEqual(self.account.budgets["999"]["amount"], "8000000")
        audit = (self.receipts / "audit.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertEqual(json.loads(audit[0])["event"], "apply")
        self.assertEqual(oct((self.receipts / "audit.jsonl").stat().st_mode & 0o777), "0o600")
        self.assertTrue(ads.apply_plan(plan, self.receipts, self.account)[1])
        self.assertEqual(len(self.account.writes()), 1)

    def test_apply_refuses_without_valid_approval_expired_tampered_or_drifted(self) -> None:
        plan = self.plan()
        self.assert_no_write(plan)
        self.approve(plan, issued_at="2026-01-01T00:00:00Z", expires_at="2026-01-01T00:10:00Z")
        self.assert_no_write(plan)
        self.approve(plan, binding={"customer_id": "5555555555"})
        self.assert_no_write(plan)
        tampered = copy.deepcopy(plan)
        tampered["operations"][3]["campaignBudgetOperation"]["update"]["amountMicros"] = "19000000"
        self.assert_no_write(tampered)
        old = ads.build_plan(copy.deepcopy(self.input), self.config, self.account,
                             now=datetime.now(timezone.utc) - timedelta(hours=25))
        self.approve(old)
        self.assert_no_write(old)
        self.approve(plan)
        self.account.budgets["999"]["amount"] = "6000000"
        self.assert_no_write(plan)
        self.assertFalse(ads.action_io.receipt_path(self.receipts, plan["plan_digest"]).exists())

    def test_apply_refuses_resigned_payload_mismatch_and_swapped_resource(self) -> None:
        plan = self.plan()
        resigned = copy.deepcopy(plan)  # consistent forward/operations copies over the cap, digest recomputed
        for operation in (resigned["actions"][3]["forward"], resigned["operations"][3]):
            operation["campaignBudgetOperation"]["update"]["amountMicros"] = "80000000"
        del resigned["plan_digest"]
        resigned["plan_digest"] = ads.action_io.digest(resigned)
        self.approve(resigned)
        self.assert_no_write(resigned)
        self.approve(plan)
        self.account.budgets["888"] = {"amount": "5000000", "shared": False}
        self.account.campaigns["111"]["budget"] = "888"  # same amount, different budget resource
        self.assert_no_write(plan)

    def test_unsent_apply_never_adopts_external_change_and_rollback_rebuilds_inverse(self) -> None:
        self.input["actions"] = self.input["actions"][:1]  # negative only: an external add equals its after-state
        plan = self.plan()
        self.approve(plan)
        with patch.object(ads, "_still_approved", side_effect=ads.GoogleAdsActionError("cancelled")):
            self.assert_no_write(plan)
        self.account.negatives.append({"level": "campaign", "parent": "111", "text": "free shoes", "match": "PHRASE",
                                       "rn": f"customers/{CUSTOMER}/campaignCriteria/111~77"})  # another operator
        self.assert_no_write(plan)
        self.assertEqual(len(self.account.negatives), 1)
        self.account.negatives.clear()
        receipt, _ = ads.apply_plan(plan, self.receipts, self.account)
        path = ads.action_io.receipt_path(self.receipts, plan["plan_digest"])
        receipt["actions"][0]["inverse"]["campaignCriterionOperation"]["remove"] = (
            f"customers/{CUSTOMER}/campaignCriteria/111~77")  # tampered: would delete a criterion never created
        ads._write_receipt(path, receipt)
        self.approve({"plan_digest": receipt["plan_digest"], "owner": receipt["owner"], "customer_id": CUSTOMER,
                      "action_set": receipt["action_set"]}, "rollback", receipt)
        sent = len(self.account.mutations)
        with self.assertRaises(ads.GoogleAdsActionError):
            ads.rollback_receipt(path, self.account)
        self.assertEqual(len(self.account.mutations), sent)

    def test_interrupted_rollback_reconciles_and_missing_audit_is_repaired(self) -> None:
        plan = self.plan()
        self.approve(plan)
        receipt, _ = ads.apply_plan(plan, self.receipts, self.account)
        path = ads.action_io.receipt_path(self.receipts, plan["plan_digest"])
        receipt.pop("audited")  # simulate an audit append lost after the applied receipt was persisted
        ads._write_receipt(path, receipt)
        (self.receipts / "audit.jsonl").unlink()
        self.assertTrue(ads.apply_plan(plan, self.receipts, self.account)[1])
        self.assertEqual(json.loads((self.receipts / "audit.jsonl").read_text(encoding="utf-8"))["event"], "apply")
        receipt = ads._load_receipt(path)
        subject = {"plan_digest": receipt["plan_digest"], "owner": receipt["owner"], "customer_id": CUSTOMER,
                   "action_set": receipt["action_set"]}
        self.approve(subject, "rollback", receipt)
        real_mutate = self.account.mutate

        def lost_response(customer, operations, validate_only):
            real_mutate(customer, operations, validate_only)
            if not validate_only:
                raise ads.GoogleAdsActionError("Google Ads request failed")
            return []

        with patch.object(self.account, "mutate", side_effect=lost_response), self.assertRaises(ads.GoogleAdsActionError):
            ads.rollback_receipt(path, self.account)
        interrupted = ads._load_receipt(path)
        self.assertEqual(interrupted["status"], "rolling_back")
        self.approve(subject, "rollback", interrupted)
        rolled_back, replayed = ads.rollback_receipt(path, self.account)
        self.assertEqual((rolled_back["status"], replayed, len(self.account.writes())), ("rolled_back", False, 2))
        self.assertEqual(self.account.negatives, [])

    def test_rollback_requires_after_state_then_restores_and_repeats_as_noop(self) -> None:
        plan = self.plan()
        self.approve(plan)
        receipt, _ = ads.apply_plan(plan, self.receipts, self.account)
        path = ads.action_io.receipt_path(self.receipts, plan["plan_digest"])
        subject = {"plan_digest": receipt["plan_digest"], "owner": receipt["owner"], "customer_id": CUSTOMER,
                   "action_set": receipt["action_set"]}
        self.approve(subject, "rollback", receipt)
        self.account.keywords["222~333"] = "ENABLED"  # someone changed the account after apply
        with self.assertRaises(ads.GoogleAdsActionError):
            ads.rollback_receipt(path, self.account)
        self.assertEqual(len(self.account.writes()), 1)
        self.account.keywords["222~333"] = "PAUSED"
        rolled_back, replayed = ads.rollback_receipt(path, self.account)
        self.assertFalse(replayed)
        self.assertEqual(self.account.negatives, [])
        self.assertEqual(self.account.campaigns["111"], {"bidding": "MANUAL_CPC", "ecpc": False, "ceiling": None,
                                                         "budget": "999"})
        self.assertEqual((self.account.keywords["222~333"], self.account.budgets["999"]["amount"]),
                         ("ENABLED", "5000000"))
        self.approve(subject, "rollback", rolled_back)
        self.assertTrue(ads.rollback_receipt(path, self.account)[1])
        self.assertEqual(len(self.account.writes()), 2)

    def test_transport_uses_fixed_endpoint_and_optional_developer_token(self) -> None:
        sent = []

        def opener(request):
            sent.append(request)
            return io.BytesIO(b'{"mutateOperationResponses": []}')

        client = ads.AdsClient("access", login_customer_id="111-222-3333", opener=opener)
        client.mutate(CUSTOMER, [{"x": {}}], validate_only=True)
        request = sent[0]
        self.assertEqual(request.full_url,
                         f"https://googleads.googleapis.com/{ads.GOOGLE_ADS_API_VERSION}/customers/{CUSTOMER}/googleAds:mutate")
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertNotIn("developer-token", headers)
        self.assertEqual(headers["login-customer-id"], "1112223333")
        self.assertEqual(json.loads(request.data)["validateOnly"], True)
        self.assertEqual(json.loads(request.data)["partialFailure"], False)
        with self.assertRaises(ads.GoogleAdsActionError):
            ads.AdsClient("")


if __name__ == "__main__":
    unittest.main()
