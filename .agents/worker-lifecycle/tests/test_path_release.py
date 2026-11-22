"""Release stale fixed-path reservations without deleting files (GH#37706)."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # CLI fixture with explicit argv, no shell
import sys
import unittest
from uuid import uuid4

from tests import test_retirement as fixtures
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.enrollment import GenerationEnrollment
from worker_lifecycle.path_release import release_replaced_path, release_vacant_path
from worker_lifecycle.retirement import _event_id
from worker_lifecycle.session import admit_session
from worker_lifecycle.storage import LifecycleRegistry, StoreConflict


class PathReleaseContract(unittest.TestCase):
    setUp = fixtures.RetirementContract.setUp
    git = fixtures.RetirementContract.git
    create = fixtures.RetirementContract.create

    def vanished(self, close=True):
        """A generation whose tree disappeared after cleanup closed admission."""
        self.create()
        self.generation = GenerationEnrollment(self.store).inspect(self.target)
        if close:
            AdmissionRegistry(self.store).close_generation(str(uuid4()), self.generation)
        self.git("worktree", "remove", "--force", str(self.target))

    def replace(self):
        """A fixed-path producer re-creates a plain tree at the same path."""
        self.git("worktree", "add", "--detach", str(self.target), "HEAD")
        (self.target / "keep.txt").write_text("replacement")

    def reserved(self):
        with self.store.connection() as connection:
            return connection.execute(
                "SELECT 1 FROM generation_admissions WHERE generation_id=?",
                (self.generation,),
            ).fetchone() is not None

    def test_vacant_path_is_released_and_can_be_recreated(self):
        self.vanished()
        result = release_vacant_path(self.store, self.target)
        self.assertEqual(result["status"], "source-absent-reconciled")
        self.assertFalse(result["cleanup_authorized"])
        self.assertFalse(self.reserved())
        self.create()
        self.assertNotEqual(GenerationEnrollment(self.store).inspect(self.target), self.generation)

    def test_vacant_release_never_touches_a_present_path(self):
        self.vanished()
        self.replace()
        self.assertEqual(release_vacant_path(self.store, self.target)["status"], "path-present")
        self.assertTrue(self.reserved())

    def test_unreserved_path_is_a_no_op(self):
        result = release_vacant_path(self.store, self.target)
        self.assertEqual(result["status"], "no-reservation")
        self.assertEqual(release_replaced_path(self.store, self.target, True)["status"],
                         "no-reservation")

    def test_replaced_path_previews_then_releases_without_deleting(self):
        self.vanished()
        self.replace()
        with self.assertRaisesRegex(StoreConflict, "reserved-path-without-enrollment-marker"):
            GenerationEnrollment(self.store).resolve(self.target, create=True)
        preview = release_replaced_path(self.store, self.target, False)
        self.assertEqual(preview["status"], "replaced-path-preview")
        self.assertTrue(preview["confirm_required"])
        self.assertTrue(self.reserved())
        released = release_replaced_path(self.store, self.target, True)
        self.assertEqual(released["status"], "replaced-path-released")
        self.assertTrue(released["operator_confirmed"])
        self.assertFalse(released["cleanup_authorized"])
        self.assertFalse(self.reserved())
        self.assertEqual((self.target / "keep.txt").read_text(), "replacement")
        replacement = GenerationEnrollment(self.store).resolve(self.target, create=True)
        self.assertNotEqual(replacement, self.generation)
        with self.store.connection() as connection:
            self.assertIsNotNone(connection.execute(
                "SELECT 1 FROM generations WHERE generation_id=?", (self.generation,),
            ).fetchone())

    def test_open_admission_with_ended_runs_is_eligible(self):
        self.vanished(close=False)
        self.replace()
        self.assertEqual(release_replaced_path(self.store, self.target, True)["status"],
                         "replaced-path-released")

    def test_enrolled_tree_is_never_released(self):
        self.create()
        self.generation = GenerationEnrollment(self.store).inspect(self.target)
        result = release_replaced_path(self.store, self.target, True)
        self.assertEqual(result["status"], "path-holds-enrolled-tree")
        self.assertTrue(self.reserved())

    def test_live_owner_keeps_reservation(self):
        self.git("worktree", "add", "--detach", str(self.target), "HEAD")
        self.generation = admit_session(self.store, self.target, os.getpid(), "live")["generation_id"]
        self.git("worktree", "remove", "--force", str(self.target))
        self.replace()
        result = release_replaced_path(self.store, self.target, True)
        self.assertEqual(result["status"], "waiting-for-runs")
        self.assertTrue(self.reserved())

    def test_planned_relocation_keeps_reservation(self):
        self.vanished()
        self.replace()
        with self.store.connection(write=True) as connection:
            LifecycleRegistry._event(connection, _event_id(self.generation, "planned"),
                                     {"type": "fixture-plan", "generation_id": self.generation})
        result = release_replaced_path(self.store, self.target, True)
        self.assertEqual(result["status"], "retry-required")
        self.assertTrue(self.reserved())

    def test_cli_preview_is_read_only(self):
        self.vanished()
        self.replace()
        entry = Path(__file__).resolve().parents[1] / "worker-registry.py"
        completed = subprocess.run(  # nosec B603 # disposable registry and repository
            [sys.executable, "-E", "-s", "-B", str(entry), "--state-dir",
             str(self.store.directory), "release-replaced-path", "--path", str(self.target)],
            capture_output=True, check=True, timeout=60,
        )
        self.assertEqual(json.loads(completed.stdout)["status"], "replaced-path-preview")
        self.assertTrue(self.reserved())


if __name__ == "__main__":
    unittest.main()
