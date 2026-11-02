"""Temporary backlog cleanup contract, using disposable worktrees only."""

from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # disposable fixture process, fixed argv
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from tests import test_retirement as fixtures
from worker_lifecycle import legacy_cleanup as legacy
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.archive_path import validate_archive_path
from worker_lifecycle.enrollment import _git_directory
from worker_lifecycle.filesystem import FilesystemValidationError
from worker_lifecycle.process import ObservationUnavailable, ProcessObservation
from worker_lifecycle.runtime import adapter_for


class ArchiveRootContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve()
        self.root = self.parent / "archives"

    def test_missing_root_is_not_created(self):
        with self.assertRaisesRegex(ValueError, "archive-path-unavailable"):
            validate_archive_path(self.root)
        self.assertFalse(self.root.exists())

    def test_validation_does_not_change_contents_or_permissions(self):
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        payload = self.root / "keep"
        payload.write_text("recovery evidence")
        payload.chmod(0o644)
        parent_mode = self.parent.stat().st_mode
        validate_archive_path(self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(payload.stat().st_mode & 0o777, 0o644)
        self.assertEqual(payload.read_text(), "recovery evidence")
        self.assertEqual(self.parent.stat().st_mode, parent_mode)

    def test_unowned_or_externally_writable_root_is_not_adopted(self):
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        with patch("worker_lifecycle.archive_path.os.getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(ValueError, "archive-path-wrong-owner"):
                validate_archive_path(self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.root.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "archive-path-externally-writable"):
            validate_archive_path(self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o777)

    def test_links_and_files_fail_with_path_without_chmod(self):
        destination = self.parent / "destination"
        destination.mkdir(mode=0o755)
        destination.chmod(0o755)
        self.root.symlink_to(destination, target_is_directory=True)
        for target in (self.root, self.root / "nested"):
            with self.assertRaises(FilesystemValidationError) as raised:
                validate_archive_path(target)
            self.assertEqual(raised.exception.path, self.root)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
        self.assertFalse((destination / "nested").exists())
        self.root.unlink()
        self.root.write_text("not a directory")
        with self.assertRaisesRegex(ValueError, "archive-path-unavailable"):
            validate_archive_path(self.root)

    def test_intermediate_directory_and_archive_privacy(self):
        archive = self.root / "repo" / "unattributed" / "capture"
        archive.mkdir(mode=0o700, parents=True)
        self.root.chmod(0o755)
        validate_archive_path(self.root, archive)
        archive.parent.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "archive-path-externally-writable"):
            validate_archive_path(self.root, archive)
        archive.parent.chmod(0o755)
        archive.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "archive-directory-not-private"):
            validate_archive_path(self.root, archive)

    def test_writable_ancestor_above_root_is_rejected(self):
        self.root.mkdir(mode=0o755)
        self.parent.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "archive-path-externally-writable"):
            validate_archive_path(self.root)


class LegacyCleanupContract(unittest.TestCase):
    git = fixtures.RetirementContract.git

    def setUp(self):
        fixtures.RetirementContract.setUp(self)
        self.scan_root = self.root / "_worktrees"
        self.scan_root.mkdir()
        environment = patch.dict(os.environ, {"AIDEVOPS_WORKTREE_BASE_DIR": str(self.scan_root)})
        environment.start()
        self.addCleanup(environment.stop)
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
        self.output.mkdir(mode=0o755, exist_ok=True)
        self.output.chmod(0o755)
        before = self.store.summary()
        preview = self.cleanup(apply=False)
        self.assertEqual(preview["eligible"], 1, preview)
        self.assertEqual(self.store.summary(), before)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o755)
        result = self.cleanup()
        self.assertEqual(result["retired"], 1, result)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o755)
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

    def test_group_writable_caller_umask_keeps_new_archives_private(self):
        self.stop_owner()
        previous = os.umask(0o002)
        try:
            result = self.cleanup()
            self.assertEqual(os.umask(0o002), 0o002)
        finally:
            os.umask(previous)
        self.assertEqual(result["retired"], 1, result)
        self.assertFalse(self.target.exists())
        with self.store.connection() as connection:
            archives = [json.loads(row[0]) for row in connection.execute(
                "SELECT payload FROM events"
            ) if json.loads(row[0]).get("type") == "legacy-worktree-archive"]
        archive = Path(archives[0]["archive"])
        self.assertEqual(archive.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)

    def test_alive_and_recent_sources_remain(self):
        result = self.cleanup()
        self.assertEqual(result["results"][0]["reason"], "process-alive")
        self.stop_owner()
        result = self.cleanup(min_age=3600)
        self.assertEqual(result["results"][0]["reason"], "too-recent")
        self.assertTrue(self.target.exists())

    def test_discovers_unregistered_git_and_unregistered_directory_without_writes(self):
        outside = self.root / "outside registry\nworktree"
        self.git("worktree", "add", "-q", "--detach", str(outside))
        orphan = self.scan_root / "orphan"
        orphan.mkdir()
        (orphan / "keep").write_text("unregistered data")
        link = self.scan_root / "alias"
        link.symlink_to(outside, target_is_directory=True)
        before = self.store.summary()
        archives = list(self.output.iterdir())
        report = self.cleanup(apply=False)
        results = {row["path"]: row for row in report["results"]}
        self.assertEqual(results[str(outside)]["reason"], "no-recorded-processes")
        self.assertIn(str(orphan), results)
        self.assertEqual(results[str(link)]["reason"], "noncanonical-path")
        self.assertNotIn(str(self.repo), results)
        self.assertEqual(len(results), 4)
        self.assertFalse(report["incomplete"])
        self.assertEqual(self.store.summary(), before)
        self.assertEqual(list(self.output.iterdir()), archives)
        self.assertEqual((orphan / "keep").read_text(), "unregistered data")

    def test_confirmed_unrecorded_source_archives_retires_and_restores(self):
        outside = self.root / "unrecorded"
        self.git("worktree", "add", "-q", "--detach", str(outside))
        (outside / "keep.txt").write_text("legacy work")
        (outside / ".gitignore").write_text("*.ignored\n")
        (outside / "private.ignored").write_text("excluded")
        before = self.store.summary()
        options = {"confirmed_paths": (str(outside),)}
        preview = self.cleanup(apply=False, **options)
        self.assertEqual(preview["eligible"], 1, preview)
        self.assertEqual(self.store.summary(), before)
        result = self.cleanup(**options)
        self.assertEqual(result["retired"], 1, result)
        self.assertEqual(result["paths"], 1)
        self.assertTrue(self.target.exists())
        self.assertFalse(outside.exists())
        with self.store.connection() as connection:
            self.assertIsNone(connection.execute(
                "SELECT 1 FROM generations WHERE path=?", (str(outside),),
            ).fetchone())
            operation = legacy.operation_id(self.store, str(outside))
            archive = legacy.receipt(connection, operation, "archive")
        self.assertTrue(archive["operator_confirmed"])
        restored = self.root / "operator-restored"
        legacy._helper("restore", archive["archive"], "--target", str(restored),
                       "--verification-copy")
        self.assertEqual((restored / "keep.txt").read_text(), "legacy work")
        self.assertFalse((restored / "private.ignored").exists())

    def test_operator_confirmation_does_not_override_alive_or_modern(self):
        options = {"confirmed_paths": (str(self.target),)}
        result = self.cleanup(**options)
        self.assertEqual(result["results"][0]["reason"], "process-alive")
        adapter = adapter_for(self.store.installation_id())
        native = adapter.observe

        def observed(identity):
            if identity.pid == self.owner.pid:
                return ProcessObservation("unknown", "fixture")
            return native(identity)

        with patch.object(type(adapter), "observe", side_effect=observed):
            result = self.cleanup(**options)
        self.assertEqual(result["results"][0]["reason"], "process-unknown")
        self.stop_owner()
        AdmissionRegistry(self.store).open_generation(
            str(uuid4()), str(uuid4()), self.target,
        )
        result = self.cleanup(**options)
        self.assertEqual(result["results"][0]["reason"], "managed-by-current-cleanup")
        self.assertTrue(self.target.exists())

    def test_confirmed_alias_keeps_recorded_owner_and_merged_modern_state(self):
        outside = self.root / "alias-target"
        self.git("worktree", "add", "-q", "--detach", str(outside))
        alias = self.root / "registered-alias"
        alias.symlink_to(outside, target_is_directory=True)
        identity = adapter_for(self.store.installation_id()).capture(self.owner.pid)
        self.store.register_attempt(str(uuid4()), identity, str(uuid4()), str(alias))
        options = {"confirmed_paths": (str(outside),)}
        result = self.cleanup(apply=False, **options)
        self.assertEqual(result["results"][0].get("reason"), "process-alive", result)
        self.assertTrue(outside.exists())
        self.stop_owner()
        AdmissionRegistry(self.store).open_generation(
            str(uuid4()), str(uuid4()), outside,
        )
        result = self.cleanup(**options)
        self.assertEqual(result["results"][0]["reason"], "managed-by-current-cleanup")
        with self.store.connection() as connection:
            item = next(row for row in legacy.inventory(connection)
                        if row["path"] == str(outside))
        self.assertEqual(len(item["generations"]), 2)
        self.assertEqual(len(item["runs"]), 1)
        self.assertTrue(item["unbound"])
        self.assertTrue(item["modern"])
        self.assertTrue(outside.exists())

    def test_confirmed_no_checkout_source_does_not_require_index_file(self):
        outside = self.root / "no-checkout"
        self.git("worktree", "add", "-q", "--detach", "--no-checkout", str(outside))
        admin = _git_directory(outside)
        self.assertFalse((admin / "index").exists())
        native = legacy._git

        def checked(*arguments):
            if "move" in arguments or "remove" in arguments:
                self.assertFalse((admin / "index").exists())
            return native(*arguments)

        with patch.object(legacy, "_git", side_effect=checked):
            result = self.cleanup(confirmed_paths=(str(outside),))
        self.assertEqual(result["retired"], 1, result)
        self.assertFalse(outside.exists())
        with self.store.connection() as connection:
            operation = legacy.operation_id(self.store, str(outside))
            archive = legacy.receipt(connection, operation, "archive")
        restored = self.root / "no-checkout-restored"
        legacy._helper("restore", archive["archive"], "--target", str(restored),
                       "--verification-copy")
        self.assertEqual(legacy._git("-C", str(restored), "ls-files", "--stage"), "")
        self.assertEqual(legacy._git("-C", str(restored), "ls-files", "--others",
                                    "--exclude-standard"), "")

    def test_ignored_head_tracked_bytes_without_index_entry_retain_source(self):
        (self.repo / ".gitignore").write_text("*.ignored\n")
        (self.repo / "tracked.ignored").write_text("committed bytes\n")
        self.git("add", ".gitignore")
        self.git("add", "--force", "tracked.ignored")
        self.git("-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "-qm", "ignored tracked file")
        for no_checkout in (True, False):
            with self.subTest(no_checkout=no_checkout):
                outside = self.root / ("missing-index" if no_checkout else "staged-deletion")
                options = ("--no-checkout",) if no_checkout else ()
                self.git("worktree", "add", "-q", "--detach", *options, str(outside))
                if no_checkout:
                    (outside / ".gitignore").write_text("*.ignored\n")
                else:
                    legacy._git("-C", str(outside), "rm", "--cached", "tracked.ignored")
                payload = outside / "tracked.ignored"
                payload.write_bytes(b"unique local bytes\x00\n")
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    legacy._snapshot(outside)
                self.assertIn(b"HEAD-tracked paths omitted", raised.exception.stderr)
                result = self.cleanup(confirmed_paths=(str(outside),))
                self.assertEqual(result["retired"], 0, result)
                self.assertEqual(payload.read_bytes(), b"unique local bytes\x00\n")
                with self.store.connection() as connection:
                    operation = legacy.operation_id(self.store, str(outside))
                    self.assertIsNone(legacy.receipt(connection, operation, "archive"))
                    self.assertIsNone(legacy.receipt(connection, operation, "plan"))

    def test_operator_archive_only_retry_requires_confirmation(self):
        self.stop_owner()
        checkpoint = legacy.checkpoint

        def interrupted(store, connection, operation, phase, payload):
            checkpoint(store, connection, operation, phase, payload)
            if phase == "archive":
                raise OSError("fixture interruption after archive receipt")

        options = {"confirmed_paths": (str(self.target),)}
        with patch.object(legacy, "checkpoint", side_effect=interrupted):
            result = self.cleanup(**options)
        self.assertEqual(result["retired"], 0)
        for apply in (False, True):
            result = self.cleanup(apply=apply)
            self.assertEqual(result["results"][0]["reason"],
                             "operator-confirmation-required")
            self.assertTrue(self.target.exists())
        result = self.cleanup(**options)
        self.assertEqual(result["retired"], 1, result)

    def test_operator_plan_needs_confirmation_again_after_interruption(self):
        self.stop_owner()
        native = legacy._git

        def interrupted(*arguments):
            value = native(*arguments)
            if "move" in arguments:
                raise OSError("fixture interruption")
            return value

        options = {"confirmed_paths": (str(self.target),)}
        with patch.object(legacy, "_git", side_effect=interrupted):
            result = self.cleanup(**options)
        self.assertEqual(result["retired"], 0)
        result = self.cleanup()
        row = next(row for row in result["results"] if row["path"] == str(self.target))
        self.assertEqual(row["reason"], "operator-confirmation-required")
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        result = self.cleanup(**options)
        self.assertEqual(result["retired"], 1, result)
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_discovery_errors_are_reported_without_hiding_other_sources(self):
        from worker_lifecycle import legacy_discovery
        with patch.object(legacy_discovery, "_registered", side_effect=OSError("unavailable")):
            report = self.cleanup(apply=False)
        self.assertTrue(report["incomplete"])
        self.assertEqual(len(report["discovery_errors"]), 1)
        self.assertEqual(report["results"][0]["reason"], "process-alive")

    def test_git_filesystem_and_registry_discovery_are_deduplicated(self):
        self.git("worktree", "move", str(self.target), str(self.scan_root / "registered"))
        moved = self.scan_root / "registered"
        identity = adapter_for(self.store.installation_id()).capture(self.owner.pid)
        self.store.register_attempt(str(uuid4()), identity, str(uuid4()), str(moved))
        report = self.cleanup(apply=False)
        self.assertEqual(sum(row["path"] == str(moved) for row in report["results"]), 1)
        row = next(row for row in report["results"] if row["path"] == str(moved))
        self.assertEqual(row["reason"], "process-alive")

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
        verify = legacy.verify_preservation

        def changed(*arguments):
            result = verify(*arguments)
            (self.target / "new-work").write_text("keep")
            return result

        with patch.object(legacy, "verify_preservation", side_effect=changed):
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

    def test_unavailable_observation_is_reported_per_path(self):
        adapter = adapter_for(self.store.installation_id())
        native = adapter.observe

        def observed(identity):
            if identity.pid == self.owner.pid:
                raise ObservationUnavailable("fixture-unavailable")
            return native(identity)

        with patch.object(type(adapter), "observe", side_effect=observed):
            result = self.cleanup()
        self.assertEqual(result["results"][0]["reason"], "fixture-unavailable")
        self.assertEqual(result["retired"], 0)
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
