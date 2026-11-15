"""Retire copied foreign-generation worktrees only in disposable repositories (GH#37828)."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # fixed fixture programs in disposable repositories
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle import foreign_retirement, retirement
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.enrollment import MARKER
from worker_lifecycle.preservation import _helper
from worker_lifecycle.storage import LifecycleRegistry, StoreConflict

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


class ForeignRetirementContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lifecycle-foreign-")
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
        self.repo, self.target = self.root / "repository", self.root / "copied tree"
        self.output = self.root / "archives"
        self.output.mkdir(mode=0o700)
        self.origin = LifecycleRegistry.initialize(self.root / "origin-state")
        # A different installation never saw the tree: its marker is foreign.
        self.store = LifecycleRegistry.initialize(self.root / "state")
        retirement._git("init", "-q", "--initial-branch=main", str(self.repo))
        self.git("config", "core.hooksPath", os.devnull)
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", "fixture")
        program = (
            "import os,sys; from pathlib import Path; "
            "from worker_lifecycle.creation import WorktreeSpec, create_worktree; "
            "from worker_lifecycle.storage import LifecycleRegistry; "
            "target=Path(sys.argv[3]); "
            "create_worktree(LifecycleRegistry(Path(sys.argv[1])), "
            "WorktreeSpec(Path(sys.argv[2]), target, 'HEAD', ('--detach',)), "
            "os.getpid(), 'owned-creator'); "
            "(target/'work.txt').write_text('unfinished result')"
        )
        subprocess.run(  # nosec B603 # fixture paths are argv, no shell
            [sys.executable, "-E", "-s", "-B", "-c", program,
             str(self.origin.directory), str(self.repo), str(self.target)],
            cwd=Path(__file__).resolve().parents[1],
            check=True, capture_output=True, timeout=30,
        )

    def git(self, *arguments):
        return retirement._git("-C", str(self.repo), *arguments)

    def admin(self):
        return Path(retirement._git("-C", str(self.target), "rev-parse", "--absolute-git-dir"))

    def retire(self, bundle=None, store=None, generation=None):
        return foreign_retirement.retire_foreign_worktree(
            store or self.store, self.target,
            retirement.ArchiveTarget("fixture/repository", "main", self.output),
            bundle, generation,
        )

    def isolate_census(self):
        """Isolate from this host's unrelated, unreadable /proc entries."""
        for module in (retirement, foreign_retirement):
            patcher = patch.object(module, "require_idle_processes")
            patcher.start()
            self.addCleanup(patcher.stop)

    def rescue(self):
        """Export, import into a fresh worktree and verify; return the bundle."""
        bundle = self.root / "bundle"
        script = str(SCRIPTS / "worktree-rescue-helper.sh")

        bash = shutil.which("bash") or "/bin/bash"

        def run(*arguments, cwd):
            return subprocess.run(  # nosec B603 # fixture helper, absolute bash, no shell
                [bash, script, *arguments], cwd=cwd, check=True,
                capture_output=True, timeout=60, text=True,
            ).stdout

        run("export", str(self.target), "--out", str(bundle), cwd=self.root)
        head = self.git("rev-parse", "HEAD")
        fresh = self.root / "fresh"
        self.git("worktree", "add", "-q", "--detach", str(fresh), head)
        output = run("import", str(bundle), cwd=fresh)
        self.assertIn("RESCUE_RECEIPT=", output)
        return bundle

    def pushed(self):
        remote = self.root / "remote.git"
        retirement._git("init", "-q", "--bare", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "origin", "HEAD:refs/heads/main")
        self.git("fetch", "-q", "origin")

    def test_local_tracking_ref_without_remote_branch_is_refused(self):
        (self.target / "work.txt").unlink()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("remote", "add", "origin", str(self.root / "missing.git"))
        with self.assertRaisesRegex(StoreConflict, "pushed-ref-unverifiable"):
            self.retire()
        self.assertTrue(self.target.exists())

    def test_pushed_clean_tree_is_archived_and_removed(self):
        (self.target / "work.txt").unlink()
        self.pushed()
        marker = (self.admin() / MARKER).read_bytes()
        result = self.retire()
        self.assertEqual(result["status"], "retired")
        self.assertTrue(result["foreign_generation"])
        self.assertFalse(result["cleanup_authorized"])
        self.assertFalse(self.target.exists())
        self.assertTrue(Path(result["archive"], "manifest.json").is_file())
        self.assertIn(b"installation_id", marker)
        self.assertEqual(self.retire(generation=result["generation_id"]), result)

    def test_rescued_tree_is_archived_with_its_work(self):
        bundle = self.rescue()
        result = self.retire(bundle)
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())
        restored = self.root / "restored"
        _helper("restore", result["archive"], "--target", str(restored),
                "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")
        # Retirement never opens admission or registers the foreign generation.
        with self.store.connection() as connection:
            self.assertIsNone(connection.execute(
                "SELECT 1 FROM generation_admissions").fetchone())

    def test_unrescued_dirty_tree_is_refused_and_kept(self):
        self.pushed()
        with self.assertRaisesRegex(StoreConflict, "rescue-or-clean-pushed-proof-required"):
            self.retire()
        self.assertEqual((self.target / "work.txt").read_text(), "unfinished result")

    def test_clean_tree_without_pushed_head_is_refused(self):
        (self.target / "work.txt").unlink()
        with self.assertRaisesRegex(StoreConflict, "head-not-reachable-from-pushed-ref"):
            self.retire()
        self.assertTrue(self.target.exists())

    def test_tree_modified_after_rescue_is_refused_and_kept(self):
        bundle = self.rescue()
        (self.target / "work.txt").write_text("changed after rescue")
        with self.assertRaisesRegex(StoreConflict, "source-changed-since-rescue"):
            self.retire(bundle)
        (self.target / "work.txt").write_text("unfinished result")
        (self.target / "late.txt").write_text("new")
        with self.assertRaisesRegex(StoreConflict, "source-changed-since-rescue"):
            self.retire(bundle)
        self.assertEqual((self.target / "late.txt").read_text(), "new")

    def test_ignored_source_is_never_removed(self):
        bundle = self.rescue()
        (self.repo / ".git" / "info" / "exclude").write_text("private.txt\n")
        (self.target / "private.txt").write_text("local data")
        with self.assertRaisesRegex(StoreConflict, "source-ignored-files-present"):
            self.retire(bundle)
        self.assertTrue((self.target / "private.txt").exists())

    def test_staged_source_is_never_removed(self):
        bundle = self.rescue()
        retirement._git("-C", str(self.target), "add", "work.txt")
        with self.assertRaisesRegex(StoreConflict, "source-staged-changes-present"):
            self.retire(bundle)
        self.assertTrue(self.target.exists())

    def test_hidden_index_flags_are_refused(self):
        retirement._git("-C", str(self.target), "add", "work.txt")
        retirement._git("-C", str(self.target), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-q", "-m", "work")
        retirement._git("-C", str(self.target), "update-index", "--assume-unchanged", "work.txt")
        (self.target / "work.txt").write_text("hidden changes")
        with self.assertRaisesRegex(StoreConflict, "source-hidden-index-flags"):
            self.retire()
        self.assertTrue(self.target.exists())

    def test_pushed_descendant_without_rescue_is_refused(self):
        bundle = self.rescue()
        fresh = self.root / "fresh"
        (fresh / "work.txt").unlink()
        retirement._git("-C", str(fresh), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-q",
                        "--allow-empty", "-m", "discarded rescue")
        with self.assertRaisesRegex(StoreConflict, "rescue-destination-changed"):
            self.retire(bundle)
        self.assertTrue(self.target.exists())

    def test_tampered_receipt_is_refused(self):
        bundle = self.rescue()
        receipt = bundle / foreign_retirement.RECEIPT
        receipt.write_text(receipt.read_text().replace("patch_sha256=", "patch_sha256=0"))
        with self.assertRaisesRegex(StoreConflict, "rescue-receipt-manifest-mismatch"):
            self.retire(bundle)
        self.assertTrue(self.target.exists())

    def test_current_installation_marker_uses_normal_cleanup(self):
        self.pushed()
        with self.assertRaisesRegex(StoreConflict, "marker-matches-current-installation"):
            self.retire(store=self.origin)
        self.assertTrue(self.target.exists())

    def test_registered_generation_is_refused(self):
        self.pushed()
        marker = (self.admin() / MARKER).read_text()
        generation = json.loads(marker)["generation_id"]
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        AdmissionRegistry(self.store).open_generation(
            str(uuid4()), generation, elsewhere,
        )
        with self.assertRaisesRegex(StoreConflict, "foreign-generation-registered"):
            self.retire()
        self.assertTrue(self.target.exists())

    def test_registered_generation_refuses_interrupted_resume(self):
        self.isolate_census()
        (self.target / "work.txt").unlink()
        self.pushed()
        generation = json.loads((self.admin() / MARKER).read_text())["generation_id"]
        native = foreign_retirement._git

        def interrupted(*arguments):
            result = native(*arguments)
            if "move" in arguments:
                raise OSError("fixture interruption after relocation")
            return result

        with patch.object(foreign_retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        # The durable reservation outlives the interruption and refuses writers.
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            AdmissionRegistry(self.store).open_generation(
                str(uuid4()), generation, elsewhere)
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            self.store.bind(str(uuid4()), str(uuid4()), generation, str(elsewhere))
        # A different generation naming the reserved source path is also refused.
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            self.store.bind(str(uuid4()), str(uuid4()), str(uuid4()), str(self.target))
        result = self.retire(generation=generation)
        self.assertEqual(result["status"], "retired")

    def test_registration_between_plan_and_relocation_loses_to_reservation(self):
        self.isolate_census()
        (self.target / "work.txt").unlink()
        self.pushed()
        generation = json.loads((self.admin() / MARKER).read_text())["generation_id"]
        native, outcomes = foreign_retirement._relocate, []

        def racing(*arguments):
            try:
                AdmissionRegistry(self.store).open_generation(
                    str(uuid4()), generation, self.target)
            except StoreConflict as error:
                outcomes.append(str(error))
            return native(*arguments)

        with patch.object(foreign_retirement, "_relocate", side_effect=racing):
            result = self.retire()
        self.assertEqual(outcomes, ["generation-retirement-reserved"])
        self.assertEqual(result["status"], "retired")

    def test_completed_retirement_keeps_path_and_generation_fenced(self):
        self.isolate_census()
        (self.target / "work.txt").unlink()
        self.pushed()
        generation = json.loads((self.admin() / MARKER).read_text())["generation_id"]
        self.retire()
        # Legacy binding accepts a previously validated path without resolving it.
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            self.store.bind(str(uuid4()), str(uuid4()), str(uuid4()), str(self.target))
        self.target.mkdir()
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            AdmissionRegistry(self.store).open_generation(
                str(uuid4()), generation, self.target)
        # A replacement directory cannot distinguish a stale writer from a new one.
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            AdmissionRegistry(self.store).open_generation(
                str(uuid4()), str(uuid4()), self.target)
        with self.assertRaisesRegex(StoreConflict, "generation-retirement-reserved"):
            self.store.bind(str(uuid4()), str(uuid4()), str(uuid4()), str(self.target))

    def test_registration_committed_first_blocks_reservation(self):
        self.pushed()
        generation = json.loads((self.admin() / MARKER).read_text())["generation_id"]
        AdmissionRegistry(self.store).open_generation(
            str(uuid4()), str(uuid4()), self.target)
        with self.assertRaisesRegex(StoreConflict, "foreign-generation-registered"):
            self.retire(generation=generation)
        self.assertTrue(self.target.exists())

    def test_interrupted_retirement_resumes_without_touching_marker(self):
        (self.target / "work.txt").unlink()
        self.pushed()
        native = foreign_retirement._git
        marker_digest = hashlib.sha256((self.admin() / MARKER).read_bytes()).hexdigest()
        admin = self.admin()

        def interrupted(*arguments):
            result = native(*arguments)
            if "move" in arguments:
                raise OSError("fixture interruption after relocation")
            return result

        with patch.object(foreign_retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        self.assertFalse(self.target.exists())
        self.assertEqual(
            hashlib.sha256((admin / MARKER).read_bytes()).hexdigest(), marker_digest)
        with self.assertRaisesRegex(StoreConflict, "foreign-source-absent"):
            self.retire()
        generation_id = json.loads((admin / MARKER).read_text())["generation_id"]
        result = self.retire(generation=generation_id)
        self.assertEqual(result["status"], "retired")
        self.assertFalse(admin.exists())

    def test_interrupted_removal_restores_git_link_before_safety_checks(self):
        (self.target / "work.txt").unlink()
        self.pushed()
        generation = json.loads((self.admin() / MARKER).read_text())["generation_id"]
        native = retirement._git

        def interrupted(*arguments):
            if "remove" in arguments and "worktree" in arguments:
                Path(arguments[-1], ".git").unlink()
                raise OSError("fixture interruption during removal")
            return native(*arguments)

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()
        # Isolate link restoration from this host's unrelated protected processes.
        with patch.object(retirement, "require_idle_processes"):
            result = self.retire(generation=generation)
        self.assertEqual(result["status"], "retired")


if __name__ == "__main__":
    unittest.main()
