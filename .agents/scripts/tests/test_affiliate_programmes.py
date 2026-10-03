#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline runtime checks of the authenticated affiliate CLI and safety boundary."""

import concurrent.futures
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from affiliate_ledger import AffiliateError, Ledger, canonical_json, latest, validate
from affiliate_signup import checkpoint, prepare
from knowledge_corpus_catalog import provision
from knowledge_corpus_context import CatalogError
from knowledge_source_contract import SourceContractError


class AffiliateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="affiliate-tests-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "knowledge"
        self.base.mkdir(mode=0o700)
        (self.base / "_knowledge").mkdir(mode=0o700)
        provision(self.base)
        self.ledger = Ledger(self.base, write=True)

    def record(self, kind="link", identifier="link-001", **extra):
        record = {"version": 1, "kind": kind, "id": identifier,
                  "programme": "amazon-us", "region": "US", "stage": "merchant",
                  "observed_at": "2026-10-03T00:00:00Z",
                  "source_url": "https://affiliate-program.amazon.com/signup"}
        defaults = {
            "link": {"url": "https://affiliate-program.amazon.com/signup?tag=public-ref&ref=a%2Bb",
                     "purpose": "product", "link_state": "verified", "http_status": 200,
                     "landing": "matched", "tracking": "preserved"},
            "account": {"state": "discovered", "confirmation": "none"},
            "profile": {"profile_ref": "protected:profile-001", "country": "US",
                        "approved": True, "data_scope": ["country"]},
            "authorization": {"profile_id": "profile-001", "action": "submit",
                              "destination": "https://affiliate-program.amazon.com/signup",
                              "agreement_sha256": "a" * 64, "data_scope": ["country"],
                              "expires_at": "2099-01-01T00:00:00Z"},
        }
        record.update(defaults.get(kind, {}))
        if kind == "authorization":
            profile = self.record("profile", "profile-001")
            record["profile_sha256"] = hashlib.sha256(canonical_json(profile).encode()).hexdigest()
        record.update(extra)
        return record

    def authorize(self, identifier="authorization-001"):
        self.ledger.append(self.record("profile", "profile-001"))
        self.ledger.append(self.record("authorization", identifier))

    def cli(self, *arguments):
        bash = shutil.which("bash")
        if bash is None:
            raise RuntimeError("Bash is required for offline CLI checks")
        return subprocess.run(
            [bash, str(SCRIPTS / "affiliate-helper.sh"), *arguments],
            env={**os.environ, "KNOWLEDGE_CORPUS_BASE": str(self.base)},
            text=True, capture_output=True, check=False, shell=False,
        )

    def test_cli_import_replay_lookup_rebuild(self):
        record = self.record()
        path = Path(self.temp.name) / "input.json"
        path.write_text(json.dumps(record))
        path.chmod(0o600)
        first = self.cli("import", "--file", str(path))
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, self.cli("import", "--file", str(path)).stdout)
        lookup = self.cli("lookup", "--programme", "amazon-us", "--purpose", "product")
        self.assertEqual(json.loads(lookup.stdout)[0]["record"]["url"], record["url"])
        self.assertEqual(json.loads(self.cli("lookup", "--purpose", "pricing").stdout), [])
        self.assertEqual(len(json.loads(self.cli("list").stdout)), 1)
        self.assertEqual(json.loads(self.cli("rebuild").stdout), {"rebuilt": 1})

    def test_public_requirements_and_prepare_need_no_corpus(self):
        self.base = Path(self.temp.name) / "absent"
        result = self.cli("requirements")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(json.loads(result.stdout)), 9)
        result = self.cli("prepare", "--programme", "tradedoubler")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["submitted"])
        self.assertEqual(self.cli("prepare", "--programme", "tradedoubler", "--live").returncode, 1)

    def test_approval_cannot_be_inferred(self):
        for state in ("submitted", "pending-review", "approved", "rejected", "closed"):
            with self.assertRaises(AffiliateError):
                self.ledger.append(self.record("account", "account-001", state=state))
        self.ledger.append(self.record("account", "account-001", state="approved",
                                       confirmation="approval-notice"))
        self.ledger.append(self.record())
        rows = latest(self.ledger.replay())
        self.assertEqual(len(rows), 2)

    def test_secrets_rejected_before_raw_persistence(self):
        for key in ("password", "cookies", "tax_identifier", "payout_account", "mfa_code", "raw_form"):
            with self.assertRaises((AffiliateError, SourceContractError)):
                self.ledger.append(self.record(**{key: "sensitive-value"}))
        for query in ("token=hidden", "access_token=hidden", "password=hidden", "%74oken=hidden"):
            with self.assertRaises(AffiliateError):
                self.ledger.append(self.record(url="https://affiliate-program.amazon.com/signup?" + query))
        self.assertEqual(self.ledger.replay(), [])

    def test_unknown_country_and_unapproved_profile_refuse_authorization(self):
        for country, approved in (("unknown", True), ("US", False)):
            self.ledger.append(self.record("profile", "profile-001", country=country, approved=approved))
            with self.assertRaises(AffiliateError):
                self.ledger.append(self.record("authorization", "authorization-001"))
        self.assertEqual(prepare("tradedoubler")["state"], "awaiting-human")

    def test_unsupported_country_not_substituted(self):
        self.ledger.append(self.record("profile", "profile-001", country="JE"))
        self.assertEqual(latest(self.ledger.replay())[0]["record"]["country"], "JE")
        self.assertIn("evidenced country eligibility", prepare("tradedoubler")["missing"])

    def test_unauthorized_and_revoked_read(self):
        with sqlite3.connect(self.base / "catalog.db") as connection:
            connection.execute("UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.read'")
        result = self.cli("list")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(str(self.base), result.stderr)

    def test_write_grant_required(self):
        with sqlite3.connect(self.base / "catalog.db") as connection:
            connection.execute("UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.write'")
        with self.assertRaises((AffiliateError, CatalogError)):
            Ledger(self.base, write=True)
        with self.assertRaises((AffiliateError, CatalogError)):
            self.ledger.append(self.record())

    def test_insecure_directory_and_symlink_refused(self):
        self.ledger.raw.chmod(0o755)
        with self.assertRaises(CatalogError):
            Ledger(self.base)
        self.ledger.raw.chmod(0o700)
        self.ledger.raw.rmdir()
        self.ledger.raw.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(CatalogError):
            Ledger(self.base)

    def test_raw_symlink_and_insecure_file_refused(self):
        self.ledger.append(self.record())
        path = next(self.ledger.raw.iterdir())
        path.chmod(0o644)
        with self.assertRaises(AffiliateError):
            self.ledger.replay()
        path.chmod(0o600)
        data = path.read_bytes()
        path.unlink()
        other = Path(self.temp.name) / "other.json"
        other.write_bytes(data)
        other.chmod(0o600)
        path.symlink_to(other)
        with self.assertRaises(OSError):
            self.ledger.replay()

    def test_cross_corpus_evidence_refused(self):
        self.ledger.append(self.record())
        path = next(self.ledger.raw.iterdir())
        payload = json.loads(path.read_bytes())
        payload["corpus_id"] = "cor_foreign"
        path.unlink()
        raw = canonical_json(payload).encode()
        path = self.ledger.raw / (hashlib.sha256(raw).hexdigest() + ".json")
        path.write_bytes(raw)
        path.chmod(0o600)
        with self.assertRaises(AffiliateError):
            self.ledger.replay()

    def test_timeout_checkpoint_never_retries(self):
        self.authorize()
        result = checkpoint(self.ledger, "authorization-001")
        self.assertEqual(result["state"], "awaiting-reconciliation")
        self.assertFalse(result["submitted"])
        with self.assertRaises(AffiliateError):
            checkpoint(self.ledger, "authorization-001")
        self.ledger.append(self.record("authorization", "authorization-002"))
        with self.assertRaises(AffiliateError):
            checkpoint(self.ledger, "authorization-002")

    def test_reconciliation_requires_checkpoint_and_new_authority(self):
        self.authorize()
        checkpoint(self.ledger, "authorization-001")
        record = latest(self.ledger.replay(), "checkpoint")[0]["record"]
        self.ledger.append({**record, "outcome": "confirmed-not-submitted"})
        with self.assertRaises(AffiliateError):
            checkpoint(self.ledger, "authorization-001")
        self.ledger.append(self.record("authorization", "authorization-002"))
        checkpoint(self.ledger, "authorization-002")
        self.assertEqual(len(latest(self.ledger.replay(), "checkpoint")), 2)

    def test_confirmation_does_not_approve_account(self):
        self.authorize()
        checkpoint(self.ledger, "authorization-001")
        record = latest(self.ledger.replay(), "checkpoint")[0]["record"]
        self.ledger.append({**record, "outcome": "confirmed-submitted"})
        self.assertEqual(latest(self.ledger.replay(), "account"), [])

    def test_concurrent_checkpoints_have_one_winner(self):
        self.authorize()
        def attempt(_):
            try:
                checkpoint(Ledger(self.base, write=True), "authorization-001")
                return True
            except AffiliateError:
                return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sum(pool.map(attempt, range(2))), 1)

    def test_expired_or_changed_authorization_refused(self):
        self.authorize()
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record("authorization", "authorization-001", agreement_sha256="b" * 64))
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record("authorization", "authorization-002", expires_at="2000-01-01T00:00:00Z"))

    def test_profile_change_invalidates_existing_authority(self):
        self.authorize()
        self.ledger.append(self.record("profile", "profile-001", profile_ref="protected:changed-profile"))
        with self.assertRaises(AffiliateError):
            checkpoint(self.ledger, "authorization-001")

    def test_replay_rejects_illegal_history(self):
        self.ledger.append(self.record())
        envelope = {"version": 1, "corpus_id": self.ledger.corpus, "sequence": 2,
                    "record": self.record(region="UK")}
        raw = canonical_json(envelope).encode()
        path = self.ledger.raw / (hashlib.sha256(raw).hexdigest() + ".json")
        path.write_bytes(raw)
        path.chmod(0o600)
        with self.assertRaises(AffiliateError):
            self.ledger.replay()

    def test_authorization_destination_queries_refused(self):
        self.ledger.append(self.record("profile", "profile-001"))
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record("authorization", "authorization-001",
                                           destination="https://affiliate-program.amazon.com/signup?ref=public"))

    def test_partial_projection_failure_retains_raw(self):
        with patch.object(self.ledger, "_projection", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.ledger.append(self.record())
        self.assertEqual(len(self.ledger.replay()), 1)
        self.ledger.append(self.record())
        self.assertTrue(self.ledger.index.is_file())
        self.assertEqual(self.ledger.rebuild(), 1)
        self.assertEqual(len(self.ledger.replay()), 1)

    def test_access_limited_and_wrong_product_links(self):
        for status in (403, 405, 429):
            with self.assertRaises(AffiliateError):
                validate(self.record(http_status=status))
            validate(self.record(http_status=status, link_state="unknown"))
        with self.assertRaises(AffiliateError):
            validate(self.record(landing="wrong-product"))
        validate(self.record(landing="wrong-product", link_state="degraded"))

    def test_version_and_identity_rebinding_fail_closed(self):
        with self.assertRaises(AffiliateError):
            validate(self.record(version=2))
        self.ledger.append(self.record())
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record(region="UK"))

    def test_programme_requirements_and_safe_deadlines(self):
        record = self.record("programme", "programme-001", merchant="amazon", network="associates",
                             signup_url="https://affiliate-program.amazon.com/signup",
                             requirements=["country", "agreement"], later_stages="unknown")
        self.ledger.append(record)
        self.ledger.append(self.record("account", "account-001", deadline_at="2027-01-01T00:00:00Z"))
        self.assertEqual(len(latest(self.ledger.replay())), 2)

    def test_future_projection_refuses_write_but_preserves_raw_reads(self):
        self.ledger.append(self.record())
        payload = json.loads(self.ledger.index.read_bytes())
        payload["version"] = 2
        self.ledger.index.write_text(json.dumps(payload))
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record(identifier="link-002"))
        self.assertEqual(len(self.ledger.replay()), 1)

    def test_oversized_observation_refused_before_commit(self):
        with self.assertRaises(AffiliateError):
            self.ledger.append(self.record(restrictions=["unknown"] * 10000))
        self.assertEqual(self.ledger.replay(), [])

    def test_malformed_projection_outputs_sanitized_refusal(self):
        self.ledger.index.write_text("[]")
        self.ledger.index.chmod(0o600)
        result = self.cli("rebuild")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
