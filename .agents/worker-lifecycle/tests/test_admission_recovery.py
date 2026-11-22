"""Recover abandoned admitted trees, without inventing creation provenance."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # owned fixture child with fixed Python program
import sys
import unittest
from unittest.mock import patch

from tests import test_retirement as fixtures
from worker_lifecycle import retirement
from worker_lifecycle.cleanup import cleanup_pass
from worker_lifecycle.session import admit_session


class AdmissionRecovery(unittest.TestCase):
    git = fixtures.RetirementContract.git
    cleanup_config = fixtures.RetirementContract.cleanup_config

    def setUp(self):
        fixtures.RetirementContract.setUp(self)
        self.git("worktree", "add", "--detach", str(self.target), "HEAD")
        (self.target / "result.txt").write_text("unfinished result\n")
        (self.target / ".gitignore").write_text("*.ignored\n")
        (self.target / "private.ignored").write_text("excluded\n")

    def ended_owner(self):
        program = (
            "import os,sys; from pathlib import Path; "
            "from worker_lifecycle.session import admit_session; "
            "from worker_lifecycle.storage import LifecycleRegistry; "
            "admit_session(LifecycleRegistry(Path(sys.argv[1])), "
            "Path(sys.argv[2]), os.getpid(), 'recovery-fixture')"
        )
        subprocess.run(  # nosec B603 # fixed program, disposable fixture paths
            [sys.executable, "-E", "-s", "-B", "-c", program,
             str(self.store.directory), str(self.target)],
            cwd=Path(__file__).resolve().parents[1],
            check=True, capture_output=True, timeout=15,
        )

    def cleanup(self):
        return cleanup_pass(self.store, self.cleanup_config(), self.output)

    def test_recovery_archives_data_without_creation_event(self):
        self.ended_owner()
        report = self.cleanup()
        self.assertEqual((report["retired"], report["failed"]), (1, 0), report)
        self.assertFalse(self.target.exists())
        with self.store.connection() as connection:
            events = [json.loads(row[0]) for row in connection.execute(
                "SELECT payload FROM events")]
        types = [event["type"] for event in events]
        self.assertNotIn("created-worktree", types)
        self.assertIn("worktree-recovery-authorized", types)
        archive = report["results"][0]["archive"]
        restored = self.root / "restored"
        retirement._run([
            "bash", str(retirement.SCRIPTS / "worktree-archive-helper.sh"),
            "restore", archive, "--target", str(restored), "--verification-copy",
        ])
        self.assertEqual((restored / "result.txt").read_text(), "unfinished result\n")
        self.assertFalse((restored / "private.ignored").exists())

    def test_live_owner_is_not_recovered(self):
        admit_session(self.store, self.target, os.getpid(), "live-fixture")
        report = self.cleanup()
        self.assertEqual(report["retired"], 0, report)
        self.assertEqual(report["results"][0]["status"], "waiting-for-runs")
        self.assertTrue(self.target.exists())

    def test_recovery_resumes_without_removing_public_replacement(self):
        self.ended_owner()
        native = retirement._git

        def interrupted(*args):
            result = native(*args)
            if "move" in args:
                raise OSError("fixture interruption")
            return result

        with patch.object(retirement, "_git", side_effect=interrupted):
            report = self.cleanup()
        self.assertEqual(report["failed"], 1, report)
        self.assertFalse(self.target.exists())
        self.target.mkdir()
        (self.target / "replacement").write_text("keep\n")
        report = self.cleanup()
        self.assertEqual(report["retired"], 1, report)
        self.assertEqual((self.target / "replacement").read_text(), "keep\n")
