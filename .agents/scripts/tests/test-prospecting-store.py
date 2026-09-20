#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused contract and recovery tests for the prospecting store."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from prospecting_contract import ContractError, ScoreUpdate  # noqa: E402
from prospecting_store import (  # noqa: E402
    ProspectingStoreError,
    StaleVersionError,
    connect,
    delete_project,
    export_project,
    import_document,
    list_leads,
    migrate,
    rescore,
    set_disposition,
    update_project_version,
)

FIXTURE = Path(__file__).parent / "fixtures" / "prospecting" / "store.json"


class ProspectingStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "store"
        self.database = connect(self.root)
        migrate(self.database)
        self.alpha = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def beta_document(self) -> dict:
        beta = copy.deepcopy(self.alpha)
        beta["project"]["project_id"] = "project-beta"
        beta["project"]["name"] = "Beta"
        beta["project"]["profile"]["secret_profile_refs"] = ["prospecting/reddit-beta"]
        beta["project"]["discovery"]["keywords"] = ["incident response"]
        beta["objects"][0]["corpus_id"] = "corpus-beta"
        beta["objects"][0]["evidence_id"] = "ev1:corpus-beta:reddit:sha256:3333"
        beta["objects"][1]["corpus_id"] = "corpus-beta"
        beta["objects"][1]["evidence_id"] = "ev1:corpus-beta:reddit:sha256:4444"
        return beta

    def test_projects_are_isolated_and_replay_is_idempotent(self) -> None:
        first = import_document(self.database, self.alpha)
        replay = import_document(self.database, self.alpha)
        import_document(self.database, self.beta_document())
        self.assertFalse(first["replayed"])
        self.assertTrue(replay["replayed"])
        self.assertEqual(2, len(list_leads(self.database, "project-alpha")))
        self.assertEqual(2, len(list_leads(self.database, "project-beta")))
        with self.assertRaises(ProspectingStoreError):
            list_leads(self.database, "unknown-project")

    def test_disposition_survives_rescore_and_stale_update_fails(self) -> None:
        import_document(self.database, self.alpha)
        self.assertEqual(2, set_disposition(self.database, "project-alpha", "ask-1", "saved", 1))
        rescore(self.database, "project-alpha", "ask-1", ScoreUpdate(91, "rubric-2", "model-2"))
        lead = list_leads(self.database, "project-alpha")[0]
        self.assertEqual("saved", lead["disposition"])
        self.assertEqual(2, lead["disposition_version"])
        self.assertEqual(91, lead["score"])
        with self.assertRaises(StaleVersionError):
            set_disposition(self.database, "project-alpha", "ask-1", "hidden", 1)

    def test_profile_and_discovery_versions_have_independent_cas(self) -> None:
        import_document(self.database, self.alpha)
        second = connect(self.root)
        migrate(second)
        self.addCleanup(second.close)
        self.assertEqual(2, update_project_version(second, "project-alpha", "profile", 1, {"facts": ["updated"]}))
        self.assertEqual(2, update_project_version(self.database, "project-alpha", "discovery", 1, {"keywords": ["updated"]}))
        with self.assertRaises(StaleVersionError):
            update_project_version(self.database, "project-alpha", "profile", 1, {})
        exported = export_project(self.database, "project-alpha")
        self.assertEqual(2, exported["project"]["profile_version"])
        self.assertEqual(2, exported["project"]["discovery_version"])

    def test_conflicts_and_malformed_records_roll_back(self) -> None:
        import_document(self.database, self.alpha)
        conflict = copy.deepcopy(self.alpha)
        conflict["objects"][0]["evidence_id"] = "ev1:other:reddit:sha256:9999"
        with self.assertRaises(ProspectingStoreError):
            import_document(self.database, conflict)
        malformed = copy.deepcopy(self.beta_document())
        malformed["leads"][0]["score"] = 101
        with self.assertRaises(ContractError):
            import_document(self.database, malformed)
        extra = copy.deepcopy(self.beta_document())
        extra["project"]["profile"]["unexpected_field"] = "not-allowed"
        with self.assertRaises(ContractError):
            import_document(self.database, extra)
        null_list = copy.deepcopy(self.beta_document())
        null_list["leads"][0]["unknowns"] = None
        with self.assertRaises(ContractError):
            import_document(self.database, null_list)
        self.assertEqual(2, len(list_leads(self.database, "project-alpha")))

    def test_dry_run_never_creates_project(self) -> None:
        result = import_document(self.database, self.alpha, dry_run=True)
        self.assertTrue(result["dry_run"])
        with self.assertRaises(ProspectingStoreError):
            list_leads(self.database, "project-alpha")

    def test_delete_requires_name_and_creates_verified_backup(self) -> None:
        import_document(self.database, self.alpha)
        with self.assertRaises(ProspectingStoreError):
            delete_project(self.database, self.root, "project-alpha", "Wrong")
        backup = delete_project(self.database, self.root, "project-alpha", "Alpha")
        self.assertTrue(backup.is_file())
        with self.assertRaises(ProspectingStoreError):
            list_leads(self.database, "project-alpha")


if __name__ == "__main__":
    unittest.main()
