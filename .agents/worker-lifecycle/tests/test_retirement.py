"""Exercise retirement only in disposable repositories, using the real backend."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # fixed creator program in disposable repositories
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle import retirement
from worker_lifecycle.cleanup import cleanup_pass
from worker_lifecycle.creation import WorktreeSpec, create_worktree
from worker_lifecycle.enrollment import MARKER, GenerationEnrollment
from worker_lifecycle.preservation import _helper
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.storage import LifecycleRegistry, StoreConflict


class RetirementContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lifecycle-retirement-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("GIT_", "AIDEVOPS_", "WORKTREE_REGISTRY_"))
        }
        environment.update(HOME=str(self.root), LC_ALL="C",
                           XDG_CONFIG_HOME=str(self.root / "config"))
        isolated = patch.dict(os.environ, environment, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)
        self.repo = self.root / "repository"
        self.target = self.root / "worktree with spaces"
        self.output = self.root / "archives"
        self.output.mkdir(mode=0o700)
        self.store = LifecycleRegistry.initialize(self.root / "state")
        retirement._git("init", "-q", "--initial-branch=main", str(self.repo))
        self.git("config", "core.hooksPath", os.devnull)
        self.git("-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "-q",
                 "--allow-empty", "-m", "fixture")

    def git(self, *arguments):
        return retirement._git("-C", str(self.repo), *arguments)

    def create(self):
        program = (
            "import os,sys; from pathlib import Path; "
            "from worker_lifecycle.creation import WorktreeSpec, create_worktree; "
            "from worker_lifecycle.storage import LifecycleRegistry; "
            "target=Path(sys.argv[3]); "
            "create_worktree(LifecycleRegistry(Path(sys.argv[1])), "
            "WorktreeSpec(Path(sys.argv[2]), target, 'HEAD', ('--detach',)), "
            "os.getpid(), 'owned-creator'); "
            "(target/'work.txt').write_text('unfinished result'); "
            "(target/'.gitignore').write_text('*.ignored\\n'); "
            "(target/'cache.ignored').write_text('discarded fixture')"
        )
        subprocess.run(  # nosec B603 # fixture paths are argv, no shell
            [sys.executable, "-E", "-s", "-B", "-c", program,
             str(self.store.directory), str(self.repo), str(self.target)],
            cwd=Path(__file__).resolve().parents[1],
            check=True, capture_output=True, timeout=30,
        )

    def retire(self):
        if not hasattr(self, "generation"):
            self.generation = GenerationEnrollment(self.store).inspect(self.target)
        return retirement.retire_worktree(
            self.store, self.target, self.generation,
            retirement.ArchiveTarget("fixture/repository", "main", self.output),
        )

    def interrupt_after_move(self):
        native = retirement._git

        def interrupted(*arguments):
            result = native(*arguments)
            if "move" in arguments:
                raise OSError("fixture interruption after relocation")
            return result

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        self.assertFalse(self.target.exists())

    def test_retirement_restores_git_data_but_not_ignored_files(self):
        self.create()
        self.generation = GenerationEnrollment(self.store).inspect(self.target)
        entry = Path(__file__).resolve().parents[1] / "worker-registry.py"
        completed = subprocess.run(  # nosec B603 # real CLI, disposable fixture
            [sys.executable, "-E", "-s", "-B", str(entry), "--state-dir",
             str(self.store.directory), "retire-worktree", "--path", str(self.target),
             "--generation-id", self.generation, "--repo", "fixture/repository",
             "--base-branch", "main", "--output-root", str(self.output)],
            capture_output=True, check=True, timeout=120,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())
        self.assertNotIn(
            f"worktree {self.target}\n", self.git("worktree", "list", "--porcelain"),
        )
        restored = self.root / "restored"
        _helper("restore", result["archive"], "--target", str(restored),
                "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")
        self.assertFalse((restored / "cache.ignored").exists())
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        self.assertEqual(self.retire(), result)
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_resume_after_move_preserves_public_replacement(self):
        self.create()
        self.interrupt_after_move()
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        self.assertEqual(self.retire()["status"], "retired")
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_git_lock_blocks_retirement_until_unlocked(self):
        self.create()
        self.git("worktree", "lock", str(self.target))
        with self.assertRaises(subprocess.CalledProcessError):
            self.retire()
        self.assertEqual((self.target / "work.txt").read_text(), "unfinished result")
        self.git("worktree", "unlock", str(self.target))
        self.assertEqual(self.retire()["status"], "retired")

    def test_late_write_before_relocation_preserves_source(self):
        self.create()
        finish = retirement._finish

        def changed_source(*arguments):
            (self.target / "late.txt").write_text("unarchived")
            return finish(*arguments)

        with patch.object(retirement, "_finish", side_effect=changed_source):
            with self.assertRaisesRegex(
                StoreConflict, "source-changed-before-relocation",
            ):
                self.retire()
        self.assertEqual((self.target / "late.txt").read_text(), "unarchived")
        self.assertIn(
            f"worktree {self.target}\n", self.git("worktree", "list", "--porcelain"),
        )
        self.assertEqual(len(list(self.output.rglob("manifest.json"))), 1)

    def test_late_write_after_move_preserves_private_source(self):
        self.create()
        native = retirement._git
        removed = []

        def changed_private(*arguments):
            if "remove" in arguments:
                removed.append(arguments)
            result = native(*arguments)
            if "move" in arguments:
                (Path(arguments[-1]) / "late.txt").write_text("unarchived")
            return result

        with patch.object(retirement, "_git", side_effect=changed_private):
            with self.assertRaisesRegex(StoreConflict, "private-worktree-changed"):
                self.retire()
        private = next(self.root.glob(".lifecycle-retire-*/tree"))
        self.assertEqual((private / "late.txt").read_text(), "unarchived")
        self.assertEqual(removed, [])
        self.assertEqual(len(list(self.output.rglob("manifest.json"))), 1)

    def test_late_lock_blocks_private_native_removal(self):
        self.create()
        native = retirement._git
        removed = []

        def locked_private(*arguments):
            if "remove" in arguments:
                removed.append(arguments)
                # Acquire the lock after final validation, just before native Git.
                native("-C", str(self.repo), "worktree", "lock", arguments[-1])
            return native(*arguments)

        with patch.object(retirement, "_git", side_effect=locked_private):
            with self.assertRaises(subprocess.CalledProcessError):
                self.retire()
        private = next(self.root.glob(".lifecycle-retire-*/tree"))
        self.assertEqual((private / "work.txt").read_text(), "unfinished result")
        self.assertEqual(len(removed), 1)
        self.assertEqual(removed[0][-1], str(private))
        self.assertEqual(removed[0].count("--force"), 1)
        self.assertEqual(len(list(self.output.rglob("manifest.json"))), 1)
        self.git("worktree", "unlock", str(private))
        self.assertEqual(self.retire()["status"], "retired")

    def test_live_creator_keeps_admission_open(self):
        create_worktree(
            self.store, WorktreeSpec(self.repo, self.target, "HEAD", ("--detach",)),
            os.getpid(), "live-creator",
        )
        result = self.retire()
        self.assertNotEqual(result["status"], "retired")
        self.assertEqual(result["admission"], "open")
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])

    def test_existing_enrollment_does_not_authorize_removal(self):
        self.git("worktree", "add", "--detach", str(self.target))
        GenerationEnrollment(self.store).resolve(self.target, create=True)
        self.assertEqual(self.retire()["status"], "coverage-gap")
        self.assertTrue(self.target.exists())

    def test_changed_archive_stops_resumption(self):
        self.create()
        generation = GenerationEnrollment(self.store).inspect(self.target)
        self.interrupt_after_move()
        plan = retirement._event(
            self.store, retirement._event_id(generation, "planned"),
        )
        receipt = retirement._event(self.store, plan["preservation_id"])
        manifest = Path(receipt["archive"]) / "manifest.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        with self.assertRaisesRegex(StoreConflict, "archive-manifest-changed"):
            self.retire()
        private = Path(plan["container"]) / "tree"
        self.assertEqual((private / "work.txt").read_text(), "unfinished result")

    def test_name_reuse_does_not_redirect_old_generation_retry(self):
        self.create()
        result = self.retire()
        create_worktree(
            self.store, WorktreeSpec(self.repo, self.target, "HEAD", ("--detach",)),
            os.getpid(), "replacement-creator",
        )
        replacement = GenerationEnrollment(self.store).inspect(self.target)
        self.assertNotEqual(replacement, self.generation)
        (self.target / "replacement").write_text("keep")
        self.assertEqual(self.retire(), result)
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_completed_remove_can_be_acknowledged_after_interruption(self):
        self.create()
        native = retirement._git

        def interrupted(*arguments):
            result = native(*arguments)
            if "remove" in arguments:
                raise OSError("fixture interruption after removal")
            return result

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        self.assertEqual(self.retire()["status"], "retired")
        self.assertFalse(self.target.exists())

    def test_incomplete_git_move_keeps_private_data_and_public_replacement(self):
        self.create()
        native = retirement._git

        def interrupted(*arguments):
            if "move" in arguments:
                Path(arguments[-2]).rename(arguments[-1])
                raise OSError("fixture interruption before Git metadata update")
            return native(*arguments)

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        with self.assertRaisesRegex(ValueError, "git-directory-backlink-mismatch"):
            self.retire()
        plan = retirement._event(
            self.store, retirement._event_id(self.generation, "planned"),
        )
        private = Path(plan["container"]) / "tree"
        self.assertEqual((private / "work.txt").read_text(), "unfinished result")
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_resume_rechecks_generation_and_owner_evidence(self):
        self.create()
        self.interrupt_after_move()
        plan = retirement._event(
            self.store, retirement._event_id(self.generation, "planned"),
        )
        marker = Path(plan["git_directory"]) / MARKER
        original = marker.read_bytes()
        value = json.loads(original)
        value["generation_id"] = str(uuid4())
        marker.write_text(json.dumps(value))
        with self.assertRaisesRegex(StoreConflict, "private-worktree-changed"):
            self.retire()
        marker.write_bytes(original)
        run = str(uuid4())
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        self.store.register(str(uuid4()), run, identity)
        self.store.bind(str(uuid4()), run, self.generation, str(self.target))
        with self.assertRaisesRegex(StoreConflict, "retirement-owner-evidence-changed"):
            self.retire()
        private = Path(plan["container"]) / "tree"
        self.assertEqual((private / "work.txt").read_text(), "unfinished result")

    def test_partial_remove_keeps_remaining_data(self):
        self.create()
        native = retirement._git

        def interrupted(*arguments):
            if "remove" in arguments:
                (Path(arguments[-1]) / "work.txt").unlink()
                raise OSError("fixture interruption during removal")
            return native(*arguments)

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        with self.assertRaisesRegex(StoreConflict, "private-worktree-changed"):
            self.retire()
        plan = retirement._event(
            self.store, retirement._event_id(self.generation, "planned"),
        )
        private = Path(plan["container"]) / "tree"
        self.assertTrue((private / ".gitignore").exists())

    def cleanup_config(self, **settings):
        config = self.root / "repos.json"
        config.write_text(json.dumps({"initialized_repos": [{
            "path": str(self.repo), "slug": "fixture/repository", **settings,
        }]}))
        return config

    def test_cleanup_cli_uses_controlled_registry_candidates(self):
        self.create()
        config = self.cleanup_config()
        entry = Path(__file__).resolve().parents[1] / "worker-registry.py"
        completed = subprocess.run(  # nosec B603 # disposable registry and repositories
            [sys.executable, "-E", "-s", "-B", str(entry), "--state-dir",
             str(self.store.directory), "cleanup", "--repos-config", str(config),
             "--output-root", str(self.output)],
            capture_output=True, check=True, timeout=120,
        )
        result = json.loads(completed.stdout)
        self.assertEqual((result["retired"], result["failed"]), (1, 0))
        self.assertFalse(self.target.exists())
        archive = result["results"][0]["archive"]
        restored = self.root / "restored"
        _helper("restore", archive, "--target", str(restored), "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")
        self.assertFalse((restored / "cache.ignored").exists())

    def test_cleanup_resumes_private_generation_not_public_replacement(self):
        self.create()
        self.interrupt_after_move()
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        result = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((result["retired"], result["failed"]), (1, 0))
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_cleanup_respects_maintenance_scope_and_live_owner(self):
        self.create()
        for settings in ({"maintenance": False}, {"local_only": True}):
            result = cleanup_pass(
                self.store, self.cleanup_config(**settings), self.output,
            )
            self.assertEqual((result["retired"], result["held"]), (0, 1))
            self.assertTrue(self.target.exists())
        live = self.root / "live"
        create_worktree(
            self.store, WorktreeSpec(self.repo, live, "HEAD", ("--detach",)),
            os.getpid(), "live-cleanup-fixture",
        )
        # Remove the ended fixture through its normal executor first.
        self.retire()
        result = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((result["retired"], result["held"]), (0, 1))
        self.assertTrue(live.exists())
        self.assertEqual(result["results"][0]["status"], "waiting-for-runs")

    def test_cleanup_rotates_unproven_generations_without_adopting_them(self):
        for name in ("unknown-one", "unknown-two"):
            path = self.root / name
            self.git("worktree", "add", "--detach", str(path), "HEAD")
            GenerationEnrollment(self.store).resolve(path, create=True)
        config = self.cleanup_config()
        results = [cleanup_pass(self.store, config, self.output, limit=1)
                   for _ in range(3)]
        ids = [result["results"][0]["generation_id"] for result in results]
        self.assertNotEqual(ids[0], ids[1])
        self.assertEqual(ids[0], ids[2])
        self.assertTrue(all(result["held"] == 1 for result in results))
        self.assertEqual(list(self.output.iterdir()), [])

    def test_child_retains_lock_after_controller_death(self):
        import time

        ready = self.root / "child-ready"
        release = self.root / "child-release"
        generation = str(uuid4())
        child = (
            "import sys,time; from pathlib import Path; "
            "Path(sys.argv[1]).touch(); deadline=time.monotonic()+10\n"
            "while not Path(sys.argv[2]).exists() and time.monotonic()<deadline:\n"
            " time.sleep(.02)\n"
        )
        program = (
            "import sys; from pathlib import Path; "
            "from worker_lifecycle.retirement import _lock; "
            "from worker_lifecycle.preservation import _run; "
            "from worker_lifecycle.storage import LifecycleRegistry\n"
            "with _lock(LifecycleRegistry(Path(sys.argv[1])), sys.argv[2]):\n"
            " _run([sys.executable,'-E','-s','-B','-c',sys.argv[3],"
            "sys.argv[4],sys.argv[5]])\n"
        )
        with subprocess.Popen(  # nosec B603 # owned finite fixture processes
            [sys.executable, "-E", "-s", "-B", "-c", program,
             str(self.store.directory), generation, child, str(ready), str(release)],
            cwd=Path(__file__).resolve().parents[1],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as controller:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists(), "owned child did not become ready")
                controller.kill()
                controller.communicate(timeout=5)
                with self.assertRaises(BlockingIOError):
                    with retirement._lock(self.store, generation):
                        pass
            finally:
                release.touch()
                if controller.poll() is None:
                    controller.communicate(timeout=15)
                # The owned child exits naturally; never signal a recycled PID.
                deadline = time.monotonic() + 5
                while True:
                    try:
                        with retirement._lock(self.store, generation):
                            break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            self.fail("owned child did not release its lock")
                        time.sleep(.02)
