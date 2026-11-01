"""Reconcile disappearance in disposable repositories without claiming a backup."""

import errno
import os
import subprocess  # nosec B404 # exception fixtures only, no process launch
import unittest
from unittest.mock import patch
from uuid import uuid4

from tests import test_retirement as fixtures
from worker_lifecycle import absence
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.cleanup import _failure_details, cleanup_pass
from worker_lifecycle.enrollment import GenerationEnrollment
from worker_lifecycle.process import ProcessObservation
from worker_lifecycle.session import admit_session


class AbsenceContract(unittest.TestCase):
    setUp = fixtures.RetirementContract.setUp
    git = fixtures.RetirementContract.git
    create = fixtures.RetirementContract.create
    cleanup_config = fixtures.RetirementContract.cleanup_config

    def missing(self, created=True):
        if created:
            self.create()
        else:
            self.git("worktree", "add", "--detach", str(self.target), "HEAD")
            GenerationEnrollment(self.store).resolve(self.target, create=True)
        self.generation = GenerationEnrollment(self.store).inspect(self.target)
        self.git("worktree", "remove", "--force", str(self.target))

    def cleanup(self):
        return cleanup_pass(self.store, self.cleanup_config(), self.output)

    def reserved(self):
        with self.store.connection() as connection:
            return connection.execute(
                "SELECT 1 FROM generation_admissions WHERE generation_id=?",
                (self.generation,),
            ).fetchone() is not None

    def test_disappeared_source_finishes_without_claiming_preservation(self):
        self.missing()
        result = self.cleanup()
        self.assertEqual((result["reconciled"], result["retired"], result["failed"]), (1, 0, 0))
        self.assertEqual(result["archive_failed"], 0)
        self.assertEqual(result["results"][0]["outcome"], "source-disappeared")
        self.assertEqual(result["results"][0]["preservation"], "unverified")
        self.assertFalse(result["results"][0]["cleanup_authorized"])
        self.assertFalse(self.reserved())
        self.assertEqual(self.cleanup()["examined"], 0)
        self.assertEqual(list(self.output.iterdir()), [])
        with self.store.connection() as connection:
            self.assertIsNotNone(connection.execute(
                "SELECT 1 FROM generations WHERE generation_id=?", (self.generation,),
            ).fetchone())

    def test_empty_reservation_is_creation_unconfirmed(self):
        self.missing(created=False)
        report = self.cleanup()
        self.assertEqual(report["results"][0]["outcome"], "creation-unconfirmed")
        self.assertFalse(self.reserved())

    def test_replay_does_not_touch_replacement_and_path_can_be_reused(self):
        self.missing()
        original = self.cleanup()["results"][0]
        self.create()
        replacement = GenerationEnrollment(self.store).inspect(self.target)
        self.assertNotEqual(replacement, self.generation)
        replay = absence.reconcile_absence(self.store, self.target, self.generation)
        self.assertEqual(replay, original)
        self.assertTrue((self.target / "work.txt").is_file())

    def test_live_owner_prevents_reconciliation(self):
        self.git("worktree", "add", "--detach", str(self.target), "HEAD")
        owner = admit_session(self.store, self.target, os.getpid(), "live-owner")
        self.generation = owner["generation_id"]
        self.git("worktree", "remove", "--force", str(self.target))
        report = self.cleanup()
        self.assertEqual(report["results"][0]["status"], "waiting-for-runs")
        self.assertTrue(self.reserved())

    def test_unknown_owner_prevents_reconciliation(self):
        self.missing()

        def unknown(store, rows, adapter):
            for row in rows:
                store.observe(str(uuid4()), row["run_id"], row["version"],
                              ProcessObservation("unknown", "fixture-unavailable"))

        with patch.object(absence, "_refresh_runs", side_effect=unknown):
            report = self.cleanup()
        self.assertEqual(report["reconciled"], 0)
        self.assertTrue(self.reserved())

    def test_new_admission_after_observation_prevents_release(self):
        self.missing()
        native = absence._runs
        calls = []

        def racing(store, generation):
            rows = native(store, generation)
            calls.append(generation)
            if len(calls) == 2:
                adapter = absence.adapter_for(store.installation_id())
                AdmissionRegistry(store).admit(
                    str(uuid4()), adapter.capture(os.getpid()), generation,
                )
            return rows

        with patch.object(absence, "_runs", side_effect=racing):
            report = self.cleanup()
        self.assertEqual(report["results"][0]["status"], "retry-required")
        self.assertTrue(self.reserved())

    def test_missing_parent_is_not_confirmed_absence(self):
        self.target = self.root / "parent" / "worktree"
        self.target.parent.mkdir()
        self.missing()
        self.target.parent.rmdir()
        report = self.cleanup()
        self.assertEqual(report["results"][0]["status"], "source-absence-unconfirmed")
        self.assertTrue(self.reserved())

    def test_replacement_before_commit_is_retained(self):
        self.missing()
        native = absence._commit_absence

        def replacement(*args):
            self.target.mkdir()
            (self.target / "keep").write_text("replacement")
            return native(*args)

        with patch.object(absence, "_commit_absence", side_effect=replacement):
            report = self.cleanup()
        self.assertEqual(report["results"][0]["status"], "retry-required")
        self.assertTrue(self.reserved())
        self.assertEqual((self.target / "keep").read_text(), "replacement")

    def test_dangling_link_is_not_absence(self):
        self.missing()
        self.target.symlink_to(self.root / "missing")
        report = self.cleanup()
        self.assertEqual((report["reconciled"], report["failed"], report["archive_failed"]), (0, 1, 0))
        self.assertTrue(self.reserved())
        self.assertTrue(self.target.is_symlink())

    def test_access_failure_is_not_absence_or_archive_failure(self):
        self.missing()
        with patch.object(absence, "_absent", side_effect=PermissionError(errno.EACCES, "private")):
            report = self.cleanup()
        self.assertEqual((report["reconciled"], report["failed"], report["archive_failed"]), (0, 1, 0))
        self.assertEqual(report["results"][0]["errno"], errno.EACCES)
        self.assertTrue(self.reserved())

    def test_journal_failure_rolls_back_release(self):
        self.missing(created=False)
        native = self.store._event

        def interrupted(*args):
            native(*args)
            raise OSError("fixture journal interruption")

        with patch.object(self.store, "_event", side_effect=interrupted):
            self.assertEqual(self.cleanup()["failed"], 1)
        self.assertTrue(self.reserved())
        self.assertEqual(self.cleanup()["reconciled"], 1)

    def test_present_source_with_missing_git_metadata_is_not_reconciled(self):
        self.create()
        self.generation = GenerationEnrollment(self.store).inspect(self.target)
        (self.target / ".git").unlink()
        report = self.cleanup()
        self.assertEqual((report["reconciled"], report["failed"]), (0, 1))
        self.assertTrue(self.reserved())
        self.assertTrue((self.target / "work.txt").exists())

class FailureDiagnostics(unittest.TestCase):
    def test_archive_validation_code_without_raw_arguments_or_stderr(self):
        error = subprocess.CalledProcessError(
            1, ["bash", "/helper/worktree-archive-helper.sh", "archive", "private-argument"],
            stderr=b"private-stderr\nValueError: merge:unpreserved_fetch_head\n",
        )
        self.assertEqual(_failure_details(error), {
            "reason": "merge:unpreserved_fetch_head", "operation": "archive",
            "returncode": 1, "archive_failure": True,
        })

    def test_generic_failure_does_not_disclose_message_or_count_as_archive(self):
        for error in (subprocess.CalledProcessError(128, ["git", "private-argument"],
                                                  stderr=b"private-stderr"),
                      ValueError("message containing private details")):
            report = _failure_details(error)
            self.assertNotIn("private", str(report))
            self.assertNotIn("archive_failure", report)

    def test_archive_timeout_is_classified_without_raw_command(self):
        error = subprocess.TimeoutExpired(
            ["bash", "/helper/worktree-archive-helper.sh", "verify-local", "private"], 120,
        )
        report = _failure_details(error)
        self.assertEqual(report["operation"], "verify-local")
        self.assertEqual(report["timeout_seconds"], 120)
        self.assertTrue(report["archive_failure"])
