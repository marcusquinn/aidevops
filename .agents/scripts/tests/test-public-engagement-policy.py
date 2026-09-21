#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused authority, race, privacy, and exact-approval regression tests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from _knowledge_social_outbound import OperationIntent, approve_operation, create_operation
from _knowledge_social_outbound_claim import ClaimRequest, claim_operation
from _knowledge_social_outbound_delegation import authorize_operation, revoke_owner_grant, store_owner_grant
from _knowledge_social_outbound_runtime import (
    AttemptOutcome,
    finalize_operation,
    mark_provider_started,
)
from _public_engagement_policy import PolicyError, parse_grant, preview
from knowledge_social_store import SocialStoreError, connect, migrate
import prospecting_auth
from prospecting_api import ProspectingAPI
from prospecting_store import connect as connect_prospecting
from prospecting_store import import_document, migrate as migrate_prospecting

FIXTURE = Path(__file__).parent / "fixtures" / "public-engagement" / "policy.json"


class PublicEngagementPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name) / "social"
        root.mkdir(mode=0o700)
        self.database = connect(root)
        migrate(self.database)
        self.database.execute(
            "INSERT INTO connections(connection_id,provider,remote_account_id,auth_profile_ref) VALUES(?,?,?,?)",
            ("conn_reddit", "reddit", "acct_reddit_42", "fixture"),
        )
        self.policy = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.grant = self.policy["grants"][0]

    def tearDown(self) -> None:
        self.database.close()
        self.temp.cleanup()

    def _operation(self, operation_id: str, body: str | None = None) -> None:
        create_operation(self.database, OperationIntent(
            connection_id="conn_reddit", remote_account_id="acct_reddit_42",
            action="reply", target_remote_id="t1_thread1",
            payload=body or "Useful answer\n\n[Automated assistant; owner-authorized]",
            app_profile="fixture", username=None, scheduled_at=100,
            created_by="owner_fixture", operation_id=operation_id, created_at=100,
        ))

    def _authorize(self, operation_id: str, current_time: int = 100) -> None:
        authorize_operation(
            self.database, operation_id, "grant_fixture",
            project_id="project_fixture", corpus_id="corpus_fixture",
            community="aidevops_test", rules_observed_at=99,
            source_observed_at=99, current_time=current_time,
        )

    def test_preview_is_disabled_by_default_and_content_free(self) -> None:
        result = preview({"schema": "aidevops.public-engagement-policy/v1", "mode": "disabled", "grants": []}, 100)
        self.assertEqual(result["default_sends"], 0)
        self.assertEqual(result["active_grant_count"], 0)
        self.assertNotIn("disclosure", result)

    def test_owner_identity_and_disclosure_are_required(self) -> None:
        with self.assertRaisesRegex(SocialStoreError, "authenticated owner"):
            store_owner_grant(self.database, self.grant, authenticated_owner_id="forged", current_time=100)
        store_owner_grant(self.database, self.grant, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_missing", "Undisclosed reply")
        with self.assertRaisesRegex(SocialStoreError, "disclosure"):
            self._authorize("op_missing")

    def test_grant_cannot_authorize_another_owners_operation(self) -> None:
        store_owner_grant(self.database, self.grant, authenticated_owner_id="owner_fixture", current_time=100)
        create_operation(self.database, OperationIntent(
            connection_id="conn_reddit", remote_account_id="acct_reddit_42",
            action="reply", target_remote_id="t1_thread1",
            payload="Answer\n\n[Automated assistant; owner-authorized]",
            app_profile="fixture", username=None, scheduled_at=100,
            created_by="owner_other", operation_id="op_other", created_at=100,
        ))
        with self.assertRaisesRegex(SocialStoreError, "grant owner"):
            self._authorize("op_other")

    def test_claim_reserves_caps_across_overlapping_grants(self) -> None:
        restrictive = dict(self.grant, account_cap=1, community_cap=1)
        store_owner_grant(self.database, restrictive, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_one")
        self._authorize("op_one")
        claim_operation(self.database, ClaimRequest("op_one", "owner_fixture", "executor_a", 100, 60))
        second = dict(restrictive, grant_id="grant_overlap", revision=1, project_id="project_other")
        store_owner_grant(self.database, second, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_two")
        authorize_operation(self.database, "op_two", "grant_overlap", project_id="project_other", corpus_id="corpus_fixture", community="aidevops_test", rules_observed_at=99, source_observed_at=99, current_time=100)
        with self.assertRaisesRegex(SocialStoreError, "cap"):
            claim_operation(self.database, ClaimRequest("op_two", "owner_fixture", "executor_b", 100, 60))

    def test_revocation_between_claim_and_start_blocks_provider(self) -> None:
        store_owner_grant(self.database, self.grant, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_race")
        self._authorize("op_race")
        claimed = claim_operation(self.database, ClaimRequest("op_race", "owner_fixture", "executor", 100, 60))
        revoke_owner_grant(self.database, "grant_fixture", "owner_fixture", 101)
        with self.assertRaisesRegex(SocialStoreError, "revoked"):
            mark_provider_started(self.database, claimed, "executor", started_at=102)

    def test_exact_owner_approval_remains_valid(self) -> None:
        self._operation("op_exact", "Human-reviewed reply")
        approve_operation(self.database, "op_exact", "owner_fixture", 200, approved_at=100)
        claimed = claim_operation(self.database, ClaimRequest("op_exact", "owner_fixture", "executor", 100, 60))
        mark_provider_started(self.database, claimed, "executor", started_at=101)
        row = self.database.execute("SELECT provider_started_at FROM outbound_attempts WHERE attempt_id=?", (claimed.attempt_id,)).fetchone()
        self.assertEqual(row[0], 101)

    def test_unknown_send_retains_its_reservation(self) -> None:
        store_owner_grant(self.database, self.grant, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_unknown")
        self._authorize("op_unknown")
        claimed = claim_operation(self.database, ClaimRequest("op_unknown", "owner_fixture", "executor", 100, 60))
        mark_provider_started(self.database, claimed, "executor", started_at=101)
        finalize_operation(
            self.database,
            claimed,
            "executor",
            AttemptOutcome("unknown", failure_class="provider_unavailable", finished_at=102),
        )
        state = self.database.execute(
            "SELECT state FROM public_engagement_reservations WHERE operation_id='op_unknown'"
        ).fetchone()[0]
        self.assertEqual(state, "unknown")

    def test_stale_rules_and_expired_grant_fail_closed(self) -> None:
        grant = dict(self.grant, rules_max_age_seconds=10, expires_at=200)
        store_owner_grant(self.database, grant, authenticated_owner_id="owner_fixture", current_time=100)
        self._operation("op_stale")
        with self.assertRaisesRegex(SocialStoreError, "rules evidence"):
            authorize_operation(
                self.database, "op_stale", "grant_fixture",
                project_id="project_fixture", corpus_id="corpus_fixture",
                community="aidevops_test", rules_observed_at=50,
                source_observed_at=99, current_time=100,
            )
        with self.assertRaisesRegex(SocialStoreError, "currently valid"):
            self._authorize("op_stale", current_time=200)

    def test_prohibited_actions_and_wildcards_fail_closed(self) -> None:
        with self.assertRaises(PolicyError):
            parse_grant(dict(self.grant, actions=["like"]))
        with self.assertRaises(PolicyError):
            parse_grant(dict(self.grant, communities=["*"]))


class ProspectingEngagementBoundaryTests(unittest.TestCase):
    def test_owner_and_executor_permissions_are_separate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "prospecting"
            database = connect_prospecting(root)
            migrate_prospecting(database)
            fixture = SCRIPTS / "tests" / "fixtures" / "prospecting" / "store.json"
            import_document(database, json.loads(fixture.read_text(encoding="utf-8")))
            auth_database = prospecting_auth.connect(root)
            owner_token, csrf = prospecting_auth.issue_owner_session(auth_database, ["project-alpha"])
            owner_id = owner_token.split("_", 2)[1]
            executor_token = prospecting_auth.issue_engagement_executor_key(auth_database, ["project-alpha"])
            read_token = prospecting_auth.issue_read_key(auth_database, ["project-alpha"])
            api = ProspectingAPI(database, auth_database)
            owner_headers = {
                "Cookie": f"prospecting_owner={owner_token}",
                "X-CSRF-Token": csrf,
                "Host": "127.0.0.1:8765",
                "Origin": "http://127.0.0.1:8765",
            }
            grant = json.loads(FIXTURE.read_text(encoding="utf-8"))["grants"][0]
            grant.update(owner_id=owner_id, project_id="project-alpha")
            path = "/v1/operator/projects/project-alpha/engagement-grants/grant_fixture"
            stored = api.request("PUT", path, owner_headers, json.dumps({"expected_version": 0, "grant": grant}).encode())
            self.assertEqual(stored.status, 200)
            read_denied = api.request("PUT", path, {"Authorization": f"Bearer {read_token}"}, b"{}")
            self.assertEqual(read_denied.status, 403)
            executor_headers = {"Authorization": f"Bearer {executor_token}"}
            self.assertEqual(api.request("GET", "/v1/projects", executor_headers).status, 401)
            evaluated = api.request(
                "POST", "/v1/executor/projects/project-alpha/engagement/evaluate",
                executor_headers, json.dumps({"grant_id": "grant_fixture", "operation_id": "op_fixture"}).encode(),
            )
            self.assertEqual(evaluated.status, 202)
            executor_admin = api.request("PUT", path, executor_headers, b"{}")
            self.assertIn(executor_admin.status, (401, 403))
            database.close()
            auth_database.close()


if __name__ == "__main__":
    unittest.main()
