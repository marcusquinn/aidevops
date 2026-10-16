#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Managed lifetime contracts; opt-in native user-systemd integration, no root."""

import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "worktree-managed-lifetime.py"
SPEC = importlib.util.spec_from_file_location("managed_lifetime", HELPER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LifetimeTests(unittest.TestCase):
    def test_absence_is_distinct_from_invalid_evidence(self):
        with closing(sqlite3.connect(":memory:")) as connection:
            with self.assertRaises(ValueError) as error:
                MODULE.load(connection, "/fixture")
            self.assertNotIsInstance(error.exception, MODULE.NotEnrolled)
            connection.execute("CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, task_id TEXT, owner_session TEXT)")
            with self.assertRaises(MODULE.NotEnrolled):
                MODULE.load(connection, "/fixture")
            MODULE.initialize(connection)
            with self.assertRaises(MODULE.NotEnrolled):
                MODULE.load(connection, "/fixture")
            connection.execute("INSERT INTO worktree_managed_lifetimes VALUES (?, ?)", ("/fixture", "{}"))
            with self.assertRaises(ValueError) as error:
                MODULE.load(connection, "/fixture")
            self.assertNotIsInstance(error.exception, MODULE.NotEnrolled)

    def record(self):
        return {"schema": 1, "manager": "pulse", "state": "running",
                "identity": {"path": "/fixture", "source_inode": "1:2"},
                "launches": [{"unit": "aidevops-worker-fixture", "boot_id": "boot",
                              "invocation": "a" * 32, "cgroup": "/fixture-never-created"}]}

    def snapshot(self):
        return {"InvocationID": "a" * 32, "MainPID": "0", "Job": "",
                "ActiveState": "active", "SubState": "exited", "ExitType": "cgroup",
                "RemainAfterExit": "yes", "Restart": "no"}

    def test_missing_receipt_and_wrong_inode_refuse(self):
        record = self.record()
        with self.assertRaises(ValueError):
            MODULE.proof(record, "1:2")
        record["state"] = "sealed"
        record["sealed_at"] = time.time()
        with self.assertRaises(ValueError):
            MODULE.proof(record, "1:2")
        record["launches"][0]["quiescence"] = self.snapshot()
        MODULE.proof(record, "1:2")
        with self.assertRaises(ValueError):
            MODULE.proof(record, "1:3")

    def test_live_descendants_and_reused_invocation_refuse(self):
        for values in ({"SubState": "running"}, {"MainPID": "123"},
                       {"InvocationID": "b" * 32}, {"Job": "44"}):
            snapshot = dict(self.snapshot(), **values)
            with self.subTest(values=values), patch.object(MODULE, "boot_id", return_value="boot"), \
                    patch.object(MODULE, "unit_snapshot", return_value=snapshot):
                with self.assertRaises(ValueError):
                    MODULE.seal(self.record())

    def test_seal_fences_future_launches(self):
        record = self.record()
        with patch.object(MODULE, "boot_id", return_value="boot"), \
                patch.object(MODULE, "unit_snapshot", return_value=self.snapshot()), \
                patch.object(Path, "read_text", return_value="populated 0\nfrozen 0\n"):
            MODULE.seal(record)
        MODULE.proof(record, "1:2")
        with self.assertRaises(ValueError):
            MODULE.reserve(record, "aidevops-worker-next")

    def test_kernel_populated_veto(self):
        with patch.object(MODULE, "boot_id", return_value="boot"), \
                patch.object(MODULE, "unit_snapshot", return_value=self.snapshot()), \
                patch.object(Path, "read_text", return_value="populated 1\nfrozen 0\n"):
            with self.assertRaises(ValueError):
                MODULE.seal(self.record())

    def test_trigger_fences_claims_but_allows_cleanup_retry(self):
        with closing(sqlite3.connect(":memory:")) as connection:
            connection.execute("CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, task_id TEXT, owner_session TEXT)")
            MODULE.initialize(connection)
            record = self.record()
            record["state"] = "sealed"
            MODULE.save(connection, record)
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("INSERT INTO worktree_owners VALUES ('/fixture', 'task', 'worker')")
            connection.execute("INSERT INTO worktree_owners VALUES ('/fixture', 'worktree-removal', 'cleanup:123')")
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("UPDATE worktree_owners SET owner_session = 'worker'")

    def test_retry_preserves_prior_quiescence(self):
        record = self.record()
        with patch.object(MODULE, "boot_id", return_value="boot"), \
                patch.object(MODULE, "unit_snapshot", return_value=self.snapshot()), \
                patch.object(Path, "read_text", return_value="populated 0\n"):
            MODULE.reserve(record, "aidevops-worker-next")
        self.assertEqual(record["state"], "reserved")
        self.assertEqual(len(record["launches"]), 2)
        self.assertIn("quiescence", record["launches"][0])
        MODULE.seal(record)
        MODULE.proof(record, "1:2")
        self.assertTrue(record["launches"][-1]["admission_cancelled"])
        with self.assertRaises(ValueError):
            MODULE.bind(record)

    def test_never_admitted_creation_can_be_closed(self):
        record = self.record()
        record.update(state="created", launches=[])
        MODULE.seal(record)
        MODULE.proof(record, "1:2")
        with self.assertRaises(ValueError):
            MODULE.reserve(record, "aidevops-worker-delayed")

    def test_admitted_work_cannot_be_disguised_as_cancelled(self):
        record = self.record()
        record["state"] = "reserved"
        with self.assertRaises(ValueError):
            MODULE.seal(record)

    @unittest.skipUnless(os.environ.get("AIDEVOPS_TEST_SYSTEMD") == "1", "explicit native systemd test")
    def test_native_child_lifetime_and_guard(self):
        base = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        self.assertTrue(base.is_dir())
        with tempfile.TemporaryDirectory(prefix="managed-lifetime-", dir=base) as temporary:
            root = Path(temporary)
            repo, worktree = root / "repo", root / "worktree"
            db = root / "registry.db"
            env = dict(os.environ, WORKTREE_REGISTRY_DB=str(db),
                       AIDEVOPS_WORKTREE_TRASH_ROOT=str(root / "recovery"),
                       AIDEVOPS_CLEANUP_LOG=str(root / "cleanup.log"))
            git = os.environ.get("AIDEVOPS_TEST_GIT_BIN", "git")
            env["PATH"] = str(Path(git).parent) + os.pathsep + env["PATH"]

            def run(argv, check=True):
                # Fixture-owned argv and disposable paths only; no shell interpolation.
                return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=30, check=check)  # nosec B603

            run([git, "init", str(repo)])
            run([git, "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--allow-empty", "-m", "fixture"])
            run([git, "-C", str(repo), "worktree", "add", "-b", "fixture", str(worktree)])
            with closing(sqlite3.connect(db)) as connection:
                connection.execute("CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, task_id TEXT, owner_session TEXT)")
            helper = [sys.executable, str(HELPER)]
            run([*helper, "enroll", str(worktree)])
            # A failed submission remains a cleanup candidate, but classification
            # must not cancel admission or manufacture a durable removal proof.
            cancelled = root / "cancelled"
            run([git, "-C", str(repo), "worktree", "add", "-b", "cancelled", str(cancelled)])
            run([*helper, "enroll", str(cancelled)])
            run([*helper, "reserve", str(cancelled), "aidevops-worker-unsubmitted-fixture"])
            run([*helper, "cleanup-ready", str(cancelled)])
            self.assertEqual(json.loads(run([*helper, "status", str(cancelled)]).stdout)["state"], "reserved")
            self.assertNotEqual(run([*helper, "proof", str(cancelled)], check=False).returncode, 0)
            run([*helper, "seal", str(cancelled)])
            run([*helper, "proof", str(cancelled)])
            run([git, "-C", str(repo), "worktree", "remove", str(cancelled)])
            try:
                # Exercise the real dispatcher wrapper, including registry propagation.
                # Parent exits after readiness; a setsid descendant outlives it.
                run(["bash", "-c", 'set -e; SCRIPT_DIR="$1"; source "$1/pulse-dispatch-worker-systemd.sh"; '
                     '_DLW_MANAGED_WORKTREE=1; _DLW_WORKTREE_PATH="$2"; LOGFILE="$3/launch.log"; '
                     '_DLW_SYSTEMD_STATE_FILE="$3/launch.state"; '
                     '_dlw_exec_systemd_user_service aidevops-worker "$3/worker.log" fixture "$4" -c '
                     '\'import subprocess,time; subprocess.Popen(["sleep","6"],start_new_session=True); time.sleep(2)\'',
                     "_", str(HELPER.parent), str(worktree), str(root), sys.executable])
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    record = json.loads(run([*helper, "status", str(worktree)]).stdout)
                    if record["state"] == "running":
                        break
                    time.sleep(0.1)
                self.assertEqual(record["state"], "running")
                unit = record["launches"][-1]["unit"]
                time.sleep(2)
                self.assertNotEqual(run([*helper, "cleanup-ready", str(worktree)], check=False).returncode, 0)
                self.assertNotEqual(run([*helper, "seal", str(worktree)], check=False).returncode, 0)
                guard = str(HELPER.parent / "audit-worktree-removal-helper.sh")
                removal = run(["bash", "-c", 'source "$1"; _worktree_remove_with_native_git "$2" fixture fixture false',
                               "_", guard, str(worktree)], check=False)
                self.assertNotEqual(removal.returncode, 0)
                self.assertTrue(worktree.is_dir())
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    result = run([*helper, "seal", str(worktree)], check=False)
                    if result.returncode == 0:
                        break
                    time.sleep(0.2)
                self.assertEqual(result.returncode, 0, result.stderr)
                run([*helper, "proof", str(worktree)])
                # Real guard: unrelated unreadable processes may be replaced, positive cwd matches may not.
                run(["bash", "-c", 'source "$1"; worktree_removal_guard "$2" fixture fixture "" degraded', "_", guard, str(worktree)])
                active = run(["bash", "-c", 'source "$1"; worktree_removal_guard "$2" fixture fixture "$2" degraded', "_", guard, str(worktree)], check=False)
                self.assertNotEqual(active.returncode, 0)
                self.assertNotEqual(run([*helper, "reserve", str(worktree), unit + "-again"], check=False).returncode, 0)
                # Exercise the production archive/verify/native-remove path, not just a boolean proof.
                (worktree / "unsaved.txt").write_text("preserve this user change\n")
                archived = run(["bash", "-c", 'set -e; source "$1"; '
                                'archive_worktree_path_recoverably "$2" fixture fixture; '
                                'archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"; '
                                'remove_archived_worktree_path "$2" "$archive" fixture fixture fixture false true; '
                                'printf "%s\\n" "$archive"', "_", guard, str(worktree)])
                archive = Path(archived.stdout.strip().splitlines()[-1])
                self.assertFalse(worktree.exists())
                self.assertEqual((archive / "unsaved.txt").read_text(), "preserve this user change\n")
                run([*helper, "proof", str(worktree), record["identity"]["source_inode"]])
            finally:
                record = json.loads(run([*helper, "status", str(worktree)]).stdout)
                for launch in record["launches"]:
                    run(["systemctl", "--user", "stop", launch["unit"]], check=False)
                    run(["systemctl", "--user", "reset-failed", launch["unit"]], check=False)
                run([git, "-C", str(repo), "worktree", "remove", str(worktree)], check=False)


if __name__ == "__main__":
    unittest.main()
