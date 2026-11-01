"""Temporary backlog cleanup contract, using disposable worktrees only."""

from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # disposable fixture process, fixed argv
import sys
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from tests import test_retirement as fixtures
from worker_lifecycle import legacy_cleanup as legacy
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.enrollment import _git_directory
from worker_lifecycle.process import ProcessObservation
from worker_lifecycle.runtime import adapter_for


class LegacyCleanupContract(unittest.TestCase):
    git = fixtures.RetirementContract.git

    def setUp(self):
        fixtures.RetirementContract.setUp(self)
        self.git("worktree", "add", "-q", "--detach", str(self.target))
        (self.target / "work.txt").write_text("unfinished work\n")
        (self.target / ".gitignore").write_text("*.ignored\n")
        (self.target / "private.ignored").write_text("not in archive")
        self.config = self.root / "repos.json"
        self.config.write_text(json.dumps({"initialized_repos": [
            {"path": str(self.repo), "slug": "fixture/repository"},
        ]}))
        self.owner = subprocess.Popen(  # nosec B603 # fixed disposable process
            [sys.executable, "-E", "-s", "-B", "-c", "import time; time.sleep(300)"],
        )
        self.addCleanup(self.stop_owner)
        identity = adapter_for(self.store.installation_id()).capture(self.owner.pid)
        self.store.register_attempt(
            str(uuid4()), identity, str(uuid4()), str(self.target),
        )

    def stop_owner(self):
        if self.owner.poll() is None:
            self.owner.terminate()
        self.owner.wait(timeout=10)

    def cleanup(self, **options):
        arguments = dict(apply=True, min_age=0, budget=120)
        arguments.update(options)
        return legacy.run(self.store, self.config, self.output, **arguments)

    def test_archive_remove_retry_and_ignored_exclusion(self):
        self.stop_owner()
        before = self.store.summary()
        preview = self.cleanup(apply=False)
        self.assertEqual(preview["eligible"], 1, preview)
        self.assertEqual(self.store.summary(), before)
        result = self.cleanup()
        self.assertEqual(result["retired"], 1, result)
        self.assertFalse(self.target.exists())
        with self.store.connection() as connection:
            self.assertEqual(connection.execute(
                "SELECT count(*) FROM generation_admissions"
            ).fetchone()[0], 0)
            archives = [json.loads(row[0]) for row in connection.execute(
                "SELECT payload FROM events"
            ) if json.loads(row[0]).get("type") == "legacy-worktree-archive"]
        restored = self.root / "restored"
        legacy._helper("restore", archives[0]["archive"], "--target", str(restored),
                       "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished work\n")
        self.assertFalse((restored / "private.ignored").exists())
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        again = self.cleanup()
        self.assertEqual(again["results"][0]["status"], "already-retired")
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_alive_and_recent_sources_remain(self):
        result = self.cleanup()
        self.assertEqual(result["results"][0]["reason"], "process-alive")
        self.stop_owner()
        result = self.cleanup(min_age=3600)
        self.assertEqual(result["results"][0]["reason"], "too-recent")
        self.assertTrue(self.target.exists())

    def test_modern_generation_is_not_legacy(self):
        self.stop_owner()
        AdmissionRegistry(self.store).open_generation(
            str(uuid4()), str(uuid4()), self.target,
        )
        result = self.cleanup()
        self.assertEqual(result["results"][0]["reason"], "managed-by-current-cleanup")
        self.assertTrue(self.target.exists())

    def test_interrupt_after_move_preserves_replacement(self):
        self.stop_owner()
        native = legacy._git

        def interrupted(*arguments):
            value = native(*arguments)
            if "move" in arguments:
                raise OSError("fixture interruption")
            return value

        with patch.object(legacy, "_git", side_effect=interrupted):
            result = self.cleanup()
        self.assertEqual(result["retired"], 0, result)
        self.assertFalse(self.target.exists())
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        configuration = self.config.read_text()
        disabled = json.loads(configuration)
        disabled["initialized_repos"][0]["maintenance"] = False
        self.config.write_text(json.dumps(disabled))
        refused = self.cleanup()
        self.assertEqual(refused["results"][0]["reason"], "repository-scope-changed")
        self.config.write_text(configuration)
        result = self.cleanup()
        self.assertEqual(result["retired"], 1, result)
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_archive_failure_retains_source(self):
        self.stop_owner()
        with patch.object(legacy, "_helper", side_effect=subprocess.SubprocessError):
            result = self.cleanup()
        self.assertEqual(result["retired"], 0, result)
        self.assertTrue((self.target / "work.txt").exists())

    def test_source_drift_after_verification_retains_source(self):
        self.stop_owner()
        verify = legacy.verify_restoration

        def changed(*arguments):
            result = verify(*arguments)
            (self.target / "new-work").write_text("keep")
            return result

        with patch.object(legacy, "verify_restoration", side_effect=changed):
            result = self.cleanup()
        self.assertEqual(result["retired"], 0, result)
        self.assertEqual((self.target / "new-work").read_text(), "keep")

    def test_archive_holds_existing_registration_writer_lock(self):
        self.stop_owner()
        helper = legacy._helper

        def checked(*arguments):
            with closing(sqlite3.connect(self.store.path, timeout=0.01)) as other:
                with self.assertRaises(sqlite3.OperationalError):
                    other.execute("BEGIN IMMEDIATE")
            return helper(*arguments)

        with patch.object(legacy, "_helper", side_effect=checked):
            result = self.cleanup()
        self.assertEqual(result["retired"], 1, result)

    def test_unknown_process_is_retained(self):
        adapter = adapter_for(self.store.installation_id())
        native = adapter.observe

        def observed(identity):
            if identity.pid == self.owner.pid:
                return ProcessObservation("unknown", "fixture")
            return native(identity)

        with patch.object(type(adapter), "observe", side_effect=observed):
            result = self.cleanup()
        self.assertEqual(result["results"][0]["reason"], "process-unknown")
        self.assertTrue(self.target.exists())

    def test_failed_candidate_does_not_starve_next_pass(self):
        another = self.root / "another-worktree"
        self.git("worktree", "add", "-q", "--detach", str(another))
        identity = adapter_for(self.store.installation_id()).capture(self.owner.pid)
        self.store.register_attempt(str(uuid4()), identity, str(uuid4()), str(another))
        self.stop_owner()
        with patch.object(legacy, "_helper", side_effect=subprocess.SubprocessError):
            first = self.cleanup(limit=1)
            second = self.cleanup(limit=1)
        self.assertEqual((first["attempted"], second["attempted"]), (1, 1))
        self.assertNotEqual(first["results"][0]["path"], second["results"][0]["path"])
        self.assertTrue(self.target.exists() and another.exists())

    def test_pulse_runs_backlog_pass_without_admissions(self):
        self.stop_owner()
        config = self.root / ".config" / "aidevops" / "repos.json"
        config.parent.mkdir(parents=True)
        config.write_text(self.config.read_text())
        with self.store.connection(write=True) as connection:
            connection.execute(
                "UPDATE events SET recorded_at="
                "strftime('%Y-%m-%dT%H:%M:%fZ','now','-2 hours')"
            )
        admin = _git_directory(self.target)
        for path in (self.target, admin / "HEAD", admin / "index"):
            os.utime(path, (time.time() - 7200, time.time() - 7200))
        library = (Path(__file__).resolve().parents[2] / "scripts"
                   / "pulse-cleanup-worktree-removal.sh")
        environment = dict(
            os.environ, AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
            AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.output),
        )
        command = ('source "$1"; LOGFILE="$2"; cleanup_worktrees 120; '
                   'printf "%s\\n" "$CLEANUP_WORKTREES_REMOVED_COUNT"')
        result = subprocess.run(  # nosec B603 B607 # fixed shell, fixture-only paths
            ["bash", "-c", command, "fixture", str(library),
             str(self.root / "pulse.log")],
            env=environment, cwd=self.root, capture_output=True, text=True, timeout=120,
            check=True,
        )
        self.assertEqual(result.stdout.strip(), "1", result.stderr)
        self.assertFalse(self.target.exists())
        self.assertIn("Observation-era cleanup: retired=1",
                      (self.root / "pulse.log").read_text())
