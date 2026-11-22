#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Seal observation must not hold SQLite locks and must reject concurrent changes."""

import importlib.util
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "worktree-managed-lifetime.py"
sys.path.insert(0, str(HELPER.parent))
SPEC = importlib.util.spec_from_file_location("managed_lifetime", HELPER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

CHANGES = {
    "generation": {"generation": "b" * 32},
    "admission_epoch": {"admission_epoch": 1},
    "both_epochs": {"admission_epoch": 1, "observed_admission_epoch": 1},
    "ownership_epoch": {"ownership_epoch": 1},
}


def base_record():
    return {"schema": 1, "manager": MODULE.owner_lifetime.MANAGER, "state": "running",
            "identity": {"path": "/fixture", "source_inode": "1:2"},
            "launches": [{"unit": "aidevops-worker-fixture", "boot_id": "boot",
                          "invocation": "a" * 32, "cgroup": "/fixture-never-created"}],
            "generation": "a" * 32, "admission_epoch": 0, "observed_admission_epoch": 0}


class SealObservedTests(unittest.TestCase):
    def run_case(self, change):
        with tempfile.TemporaryDirectory() as directory:
            database = str(Path(directory) / "registry.db")
            with closing(sqlite3.connect(database, isolation_level=None)) as connection, \
                    closing(sqlite3.connect(database, isolation_level=None, timeout=0)) as writer:
                connection.execute("CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, task_id TEXT, owner_session TEXT)")
                MODULE.initialize(connection)
                MODULE.save(connection, base_record())

                def observe(observed):
                    self.assertFalse(connection.in_transaction)
                    # This would fail immediately if a writer/read lock were retained.
                    writer.execute("BEGIN IMMEDIATE")
                    current = MODULE.load(writer, "/fixture")
                    current.update(CHANGES.get(change, {}))
                    MODULE.save(writer, current)
                    writer.execute("COMMIT")
                    observed.update(state="sealed", sealed_at=time.time())

                with patch.object(MODULE, "verify_identity"), patch.object(MODULE, "seal", side_effect=observe):
                    if change:
                        with self.assertRaises(ValueError):
                            MODULE.seal_observed(connection, Path("/fixture"), "seal", [])
                        connection.rollback()
                    else:
                        MODULE.seal_observed(connection, Path("/fixture"), "seal", [])
                current = MODULE.load(connection, "/fixture")
                self.assertEqual(current["state"], "running" if change else "sealed")
                for key, value in CHANGES.get(change, {}).items():
                    self.assertEqual(current[key], value)

    def test_seal_observations_allow_writers_and_reject_concurrent_changes(self):
        for change in (None, *CHANGES):
            with self.subTest(change=change):
                self.run_case(change)


if __name__ == "__main__":
    unittest.main()
