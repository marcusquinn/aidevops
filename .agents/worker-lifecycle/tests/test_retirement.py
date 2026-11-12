"""Exercise retirement only in disposable repositories, using the real backend."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess  # nosec B404 # fixed creator program in disposable repositories
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle import interrupted_removal, pull_requests, retirement
from worker_lifecycle.admission import AdmissionClosed, AdmissionRegistry
from worker_lifecycle.cleanup import cleanup_pass, cleanup_worktree, retire_enrolled_only
from worker_lifecycle.cleanup_plan import enrolled_only_event_id
from worker_lifecycle.creation import WorktreeSpec, create_worktree
from worker_lifecycle.enrollment import MARKER, GenerationEnrollment
from worker_lifecycle.preservation import _helper
from worker_lifecycle.refusal import refusal_code
from worker_lifecycle.retirement_proof import verify_retirement
from worker_lifecycle.runtime import adapter_for
from worker_lifecycle.storage import LifecycleRegistry, StoreConflict


def age_past_clock_slack():
    """Let fixture content predate the backdated deletion-only boundary.

    The boundary sits one clock slack before the snapshot check (GH#37326), so
    content a fast runner wrote inside that window would count as a late change.
    """
    time.sleep(interrupted_removal.CLOCK_SLACK_NS / 1e9)


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
        self.output.chmod(0o755)
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
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o755)
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

    def codex_config(self):
        """Install runtime-local configuration in the disposable worktree."""
        self.git("config", "extensions.worktreeConfig", "true")
        admin = retirement._git("-C", str(self.target), "rev-parse", "--absolute-git-dir")
        config = Path(admin) / "config.worktree"
        config.write_bytes(b'[codex]\n\tlocalEnvironmentConfigPath = /fixture/environment.toml\n')
        return config

    def test_codex_config_retirement_preserves_bytes_without_restoring_config(self):
        """Retire through the real backend while retaining omitted config bytes."""
        self.create()
        config = self.codex_config()
        content = config.read_bytes()
        result = self.retire()
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())
        self.assertFalse(config.exists())
        self.assertNotIn(f"worktree {self.target}\n", self.git("worktree", "list", "--porcelain"))
        archive = Path(result["archive"])
        self.assertEqual((archive / "worktree-config-v1").read_bytes(), content)
        _helper("verify", str(archive))
        restored = self.root / "codex-restored"
        _helper("restore", str(archive), "--target", str(restored), "--verification-copy")
        admin = retirement._git("-C", str(restored), "rev-parse", "--absolute-git-dir")
        self.assertFalse((Path(admin) / "config.worktree").exists())
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")

    def test_codex_config_does_not_authorize_unowned_retirement(self):
        """Runtime config must not bypass the existing ownership requirement."""
        self.git("worktree", "add", "--detach", str(self.target))
        GenerationEnrollment(self.store).resolve(self.target, create=True)
        config = self.codex_config()
        content = config.read_bytes()
        self.assertEqual(self.retire()["status"], "coverage-gap")
        self.assertTrue(self.target.is_dir())
        self.assertEqual(config.read_bytes(), content)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_codex_config_preservation_failure_keeps_source(self):
        """Mixed runtime and unknown keys fail closed before source removal."""
        self.create()
        config = self.codex_config()
        content = config.read_bytes() + b'[fixture]\n\tprivate = keep\n'
        config.write_bytes(content)
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.retire()
        self.assertIn("git_admin:requires_preservation:config.worktree", str(caught.exception.stderr))
        self.assertTrue(self.target.is_dir())
        self.assertEqual(config.read_bytes(), content)
        self.assertEqual((self.target / "work.txt").read_text(), "unfinished result")

    def test_codex_config_drift_before_relocation_keeps_source(self):
        """Changed config invalidates preservation proof at the retirement boundary."""
        self.create()
        config = self.codex_config()
        original = config.read_bytes()
        changed = original.replace(b'environment', b'other')
        finish = retirement._finish

        def changed_source(*arguments):
            """Inject a config write after capture and before relocation."""
            config.write_bytes(changed)
            return finish(*arguments)

        with patch.object(retirement, "_finish", side_effect=changed_source):
            with self.assertRaisesRegex(StoreConflict, "source-changed-before-relocation"):
                self.retire()
        self.assertTrue(self.target.is_dir())
        self.assertEqual(config.read_bytes(), changed)
        self.assertEqual((self.target / "work.txt").read_text(), "unfinished result")
        archive = next(self.output.rglob("worktree-config-v1"))
        self.assertEqual(archive.read_bytes(), original)

    def test_resume_after_move_preserves_public_replacement(self):
        self.create()
        self.interrupt_after_move()
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        self.assertEqual(self.retire()["status"], "retired")
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def test_resume_plan_rechecks_live_source(self):
        self.create()
        with patch.object(retirement, "_finish", side_effect=OSError("interrupted")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.retire()
        previous = Path.cwd()
        try:
            os.chdir(self.target)
            with self.assertRaisesRegex(ValueError, "live-process-reference"):
                self.retire()
            self.assertTrue(self.target.is_dir())
        finally:
            os.chdir(previous)
        self.assertEqual(self.retire()["status"], "retired")

    def test_resume_move_rechecks_private_tree_not_public_replacement(self):
        self.create()
        self.interrupt_after_move()
        plan = retirement._event(
            self.store, retirement._event_id(self.generation, "planned"),
        )
        private = Path(plan["container"]) / "tree"
        previous = Path.cwd()
        try:
            os.chdir(private)
            with self.assertRaisesRegex(ValueError, "live-process-reference"):
                self.retire()
            self.assertTrue(private.is_dir())
            self.target.mkdir()
            os.chdir(self.target)
            self.assertEqual(self.retire()["status"], "retired")
            self.assertTrue(self.target.is_dir())
        finally:
            os.chdir(previous)

    def test_git_lock_blocks_retirement_until_unlocked(self):
        self.create()
        self.git("worktree", "lock", str(self.target))
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.retire()
        self.assertEqual(refusal_code(caught.exception, "cleanup-worktree"), "worktree-locked")
        self.assertEqual((self.target / "work.txt").read_text(), "unfinished result")
        self.git("worktree", "unlock", str(self.target))
        self.assertEqual(self.retire()["status"], "retired")

    def test_unlocked_substring_is_not_a_worktree_lock(self):
        error = subprocess.CalledProcessError(
            1, ["git", "worktree", "remove"],
            stderr=b"fatal: path /tmp/unlocked is unavailable\n",
        )
        self.assertIsNone(refusal_code(error, "cleanup-worktree"))
        locked = subprocess.CalledProcessError(
            1, ["git", "worktree", "remove"],
            stderr=b"archive-snapshot: git_admin:unknown_entry:locked\n",
        )
        self.assertEqual(refusal_code(locked, "cleanup-worktree"), "worktree-locked")

    def test_creation_names_disk_quota_only_from_strerror(self):
        # GH#37922: only EDQUOT/ENOSPC text proves exhaustion; paths never leak.
        def add_failure(stderr):
            return subprocess.CalledProcessError(128, ["git", "worktree", "add"], stderr=stderr)

        quota = add_failure(b"error: unable to write file worktree/locked/x: Disk quota exceeded\n")
        full = add_failure(b"fatal: unable to write new index file: No space left on device\n")
        generic = add_failure(b"error: unable to write file worktree/x\n")
        self.assertEqual(refusal_code(quota, "create-worktree"), "disk-quota-exceeded")
        self.assertEqual(refusal_code(full, "create-worktree"), "disk-full")
        self.assertEqual(refusal_code(generic, "create-worktree"), "git-worktree-add-failed")
        self.assertIsNone(refusal_code(quota, "cleanup-worktree"))

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
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                self.retire()
        self.assertEqual(refusal_code(caught.exception, "cleanup-worktree"), "worktree-locked")
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

    def enrolled_only(self, confirm):
        return retire_enrolled_only(
            self.store, self.cleanup_config(), self.output, self.target, confirm,
        )

    def test_enrolled_only_previews_then_archives_and_keeps_branch(self):
        self.git("worktree", "add", "-b", "chore/probe", str(self.target))
        (self.target / "README.md").write_text("staged change")
        retirement._git("-C", str(self.target), "add", "README.md")
        GenerationEnrollment(self.store).resolve(self.target, create=True)
        created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        preview = self.enrolled_only(False)
        self.assertEqual(preview["status"], "enrolled-only-preview")
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])
        result = self.enrolled_only(True)
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())
        self.assertIn("chore/probe", self.git("branch", "--list", "chore/probe"))
        self.assertTrue(list(Path(result["archive"]).rglob("staged.patch")))
        with self.store.connection() as connection:
            self.assertIsNone(connection.execute(
                "SELECT 1 FROM generation_admissions").fetchone())
        proof = verify_retirement(
            self.store, self.target, "fixture/repository", "chore/probe", created_at,
        )
        self.assertEqual(proof["status"], "retirement-verified")
        self.assertFalse(proof["cleanup_authorized"])
        receipts = self.root / "receipts"
        receipts.mkdir(mode=0o700)
        receipt = receipts / "fixture_repository-1.json"
        receipt.write_text(json.dumps({
            "worktree": str(self.target), "repository": "fixture/repository",
            "branch": "chore/probe", "created_at": created_at,
            "pr_number": 1, "resource_cleanup_state": "CLEANUP_DEFERRED",
        }))
        scripts = Path(__file__).resolve().parents[2] / "scripts"
        bash = shutil.which("bash")
        if bash is None:
            raise FileNotFoundError("bash is required for the cleanup receipt bridge")
        subprocess.run(  # nosec B603 # real consumer, disposable registry and archive
            [bash, "-c", 'source "$1/full-loop-cleanup-receipt.sh"; '
             'full_loop_mark_cleanup_cleaned_for_identity fixture/repository 1 "$2" "$3"',
             "fixture", str(scripts), str(self.target),
             str(self.root / "missing-removal.log")],
            env={**os.environ, "AIDEVOPS_LIFECYCLE_STATE_DIR": str(self.store.directory),
                 "AIDEVOPS_FULL_LOOP_CLEANUP_DIR": str(receipts)},
            check=True, capture_output=True, timeout=120,
        )
        self.assertEqual(json.loads(receipt.read_text())["resource_cleanup_state"], "CLEANED")
        for repository, branch, timestamp in (
            ("other/repository", "chore/probe", created_at),
            ("fixture/repository", "other-branch", created_at),
            ("fixture/repository", "chore/probe", "2000-01-01T00:00:00Z"),
            ("fixture/repository", "chore/probe", "9999-01-01T00:00:00Z"),
        ):
            with self.subTest(repository=repository, branch=branch, timestamp=timestamp):
                with self.assertRaises(StoreConflict):
                    verify_retirement(self.store, self.target, repository, branch, timestamp)
        self.target.symlink_to(self.root / "missing-replacement", target_is_directory=True)
        with self.assertRaises(StoreConflict):
            verify_retirement(self.store, self.target, "fixture/repository", "chore/probe", created_at)
        self.target.unlink()
        manifest = Path(result["archive"]) / "manifest.json"
        manifest.write_text(manifest.read_text() + "\n")
        with self.assertRaises(StoreConflict):
            verify_retirement(self.store, self.target, "fixture/repository", "chore/probe", created_at)

    def test_enrolled_only_refuses_any_admitted_run(self):
        self.create()
        result = self.enrolled_only(True)
        self.assertEqual(result["status"], "not-enrolled-only")
        self.assertTrue(self.target.exists())

    def test_enrolled_only_invalid_archive_root_keeps_admission_open(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        invalid = self.output / "not-a-directory"
        invalid.write_text("keep")
        with self.assertRaises(ValueError):
            retire_enrolled_only(
                self.store, self.cleanup_config(), invalid, self.target, True,
            )
        with self.store.connection() as connection:
            admission = connection.execute(
                "SELECT state FROM generation_admissions WHERE generation_id=?",
                (generation,),
            ).fetchone()
        self.assertEqual(admission["state"], "open")
        self.assertIsNone(retirement._event(self.store, enrolled_only_event_id(generation)))
        self.assertTrue(self.target.exists())
        self.assertEqual(invalid.read_text(), "keep")

    def test_enrolled_only_invalid_archive_keeps_admission_open(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        self.output.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "archive-path-externally-writable"):
            self.enrolled_only(True)
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertIsNone(retirement._event(
            self.store, enrolled_only_event_id(generation),
        ))
        self.assertEqual(self.enrolled_only(False)["admission"], "open")
        self.output.chmod(0o700)
        self.assertEqual(self.enrolled_only(True)["status"], "retired")

    def test_enrolled_only_contained_archive_keeps_admission_open(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        git_directory = Path(retirement._git(
            "-C", str(self.target), "rev-parse", "--absolute-git-dir",
        ))
        for parent in (self.target, git_directory):
            for root in (parent, parent / "archives"):
                with self.subTest(root=root):
                    existed = root.exists()
                    with self.assertRaisesRegex(
                        ValueError, "archive-output-must-be-outside-worktree",
                    ):
                        retire_enrolled_only(
                            self.store, self.cleanup_config(), root, self.target, True,
                        )
                    self.assertEqual(root.exists(), existed)
                    self.assertTrue(self.target.exists())
                    self.assertIsNone(retirement._event(
                        self.store, enrolled_only_event_id(generation),
                    ))
                    self.assertEqual(self.enrolled_only(False)["admission"], "open")
        self.assertEqual(self.enrolled_only(True)["status"], "retired")

    def test_enrolled_only_admission_race_loses_after_closure(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        self.assertEqual(self.enrolled_only(False)["status"], "enrolled-only-preview")
        AdmissionRegistry(self.store).authorize_enrolled_only(
            enrolled_only_event_id(generation), generation)
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        with self.assertRaises(AdmissionClosed):
            AdmissionRegistry(self.store).admit(str(uuid4()), identity, generation)
        # Admitted first: the operation refuses instead.
        other = self.root / "second"
        self.git("worktree", "add", "--detach", str(other))
        second = GenerationEnrollment(self.store).resolve(other, create=True)
        AdmissionRegistry(self.store).admit(str(uuid4()), identity, second)
        with self.assertRaisesRegex(StoreConflict, "generation-has-admitted-owner"):
            AdmissionRegistry(self.store).authorize_enrolled_only(
                enrolled_only_event_id(second), second)

    def test_enrolled_only_public_path_refuses_admission_before_outer_check(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        contender = LifecycleRegistry(self.store.directory)
        self.assertTrue(AdmissionRegistry(contender).admit(
            str(uuid4()), identity, generation))

        self.assertEqual(self.enrolled_only(True)["status"], "not-enrolled-only")
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertIsNone(retirement._event(
            self.store, enrolled_only_event_id(generation)))

    def test_enrolled_only_public_path_refuses_admission_before_inner_check(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        contender = LifecycleRegistry(self.store.directory)
        authorize = AdmissionRegistry.authorize_enrolled_only

        def admit_before_authorization(registry, event_id, generation_id):
            self.assertTrue(AdmissionRegistry(contender).admit(
                str(uuid4()), identity, generation_id))
            return authorize(registry, event_id, generation_id)

        with patch.object(AdmissionRegistry, "authorize_enrolled_only",
                          new=admit_before_authorization):
            with self.assertRaisesRegex(StoreConflict, "generation-has-admitted-owner"):
                self.enrolled_only(True)
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertIsNone(retirement._event(
            self.store, enrolled_only_event_id(generation)))

    def test_enrolled_only_public_path_excludes_admission_after_inner_check(self):
        self.git("worktree", "add", "--detach", str(self.target))
        generation = GenerationEnrollment(self.store).resolve(self.target, create=True)
        identity = adapter_for(self.store.installation_id()).capture(os.getpid())
        contender = LifecycleRegistry(self.store.directory)
        connect = contender._connect
        event = self.store._event
        run = str(uuid4())
        attempts = []

        def no_lock_wait():
            connection = connect()
            connection.execute("PRAGMA busy_timeout=0")
            return connection

        def compete_after_checks(connection, event_id, payload):
            if event_id == enrolled_only_event_id(generation):
                # This event is written after both inner eligibility checks but
                # before closure. Never wait for a competing commit under the lock.
                self.assertTrue(connection.in_transaction)
                with ThreadPoolExecutor(max_workers=1) as executor:
                    attempt = executor.submit(
                        AdmissionRegistry(contender).admit, run, identity, generation,
                    )
                    with self.assertRaisesRegex(
                        sqlite3.OperationalError, "database is locked",
                    ):
                        attempt.result(timeout=5)
                attempts.append(event_id)
            return event(connection, event_id, payload)

        with patch.object(contender, "_connect", side_effect=no_lock_wait):
            with patch.object(self.store, "_event", side_effect=compete_after_checks):
                result = self.enrolled_only(True)
            self.assertEqual(attempts, [enrolled_only_event_id(generation)])
            self.assertEqual(result["status"], "retired")
            with self.assertRaisesRegex(AdmissionClosed, "generation-not-open"):
                AdmissionRegistry(contender).admit(run, identity, generation)
        self.assertFalse(self.target.exists())
        self.assertTrue(Path(result["archive"]).is_dir())
        with self.store.connection() as connection:
            self.assertIsNone(connection.execute(
                "SELECT 1 FROM bindings WHERE generation_id=?", (generation,),
            ).fetchone())

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

    def interrupt_removal(self, late=None):
        """Delete part of the private tree, then fail as a timed-out native removal."""
        age_past_clock_slack()
        native = retirement._git

        def interrupted(*arguments):
            if "remove" in arguments:
                (Path(arguments[-1]) / "work.txt").unlink()
                if late is not None:
                    late(Path(arguments[-1]))
                raise OSError("fixture interruption during removal")
            return native(*arguments)

        with patch.object(retirement, "_git", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "fixture interruption"):
                self.retire()

    def test_partial_remove_resumes_when_only_deletions_followed(self):
        self.create()
        self.interrupt_removal()
        report = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((report["retired"], report["failed"]), (1, 0), report)
        self.assertEqual(list(self.root.glob(".lifecycle-retire-*")), [])
        self.assertNotIn(".lifecycle-retire-", self.git("worktree", "list", "--porcelain"))
        restored = self.root / "restored"
        _helper("restore", report["results"][0]["archive"], "--target", str(restored),
                "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")

    def test_partial_remove_keeps_data_written_after_removal_began(self):
        self.create()
        self.interrupt_removal(lambda tree: (tree / ".gitignore").write_text("late\n"))
        with self.assertRaisesRegex(ValueError, "interrupted-removal-content-changed"):
            self.retire()
        plan = retirement._event(
            self.store, retirement._event_id(self.generation, "planned"),
        )
        private = Path(plan["container"]) / "tree"
        self.assertEqual((private / ".gitignore").read_text(), "late\n")

    def test_partial_remove_resumes_after_git_deleted_its_link(self):
        self.create()
        self.interrupt_removal(lambda tree: (tree / ".git").unlink())
        report = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((report["retired"], report["failed"]), (1, 0), report)
        self.assertEqual(list(self.root.glob(".lifecycle-retire-*")), [])

    def test_partial_remove_keeps_data_written_before_removal_was_journaled(self):
        self.create()
        record = retirement._record

        def late(store, generation, phase, data):
            if phase == "removing":
                plan = retirement._event(store, retirement._event_id(generation, "planned"))
                (Path(plan["container"]) / "tree" / ".gitignore").write_text("late\n")
            record(store, generation, phase, data)

        with patch.object(retirement, "_record", side_effect=late):
            self.interrupt_removal()
        with self.assertRaisesRegex(ValueError, "interrupted-removal-content-changed"):
            self.retire()

    def test_failed_resume_backs_off_instead_of_holding_the_slot(self):
        self.create()
        self.interrupt_removal(lambda tree: (tree / ".gitignore").write_text("late\n"))
        config = self.cleanup_config()
        report = cleanup_pass(self.store, config, self.output)
        self.assertEqual(report["failed"], 1, report)
        self.assertTrue(report["results"][0]["quarantined"], report)
        report = cleanup_pass(self.store, config, self.output)
        self.assertEqual((report["examined"], report["quarantined"]), (0, 1), report)

    def cleanup_config(self, **settings):
        config = self.root / "repos.json"
        config.write_text(json.dumps({"initialized_repos": [{
            "path": str(self.repo), "slug": "fixture/repository", **settings,
        }]}))
        return config

    def test_cleanup_cli_uses_controlled_registry_candidates(self):
        self.create()
        self.output.chmod(0o755)
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
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o755)
        self.assertFalse(self.target.exists())
        archive = result["results"][0]["archive"]
        restored = self.root / "restored"
        _helper("restore", archive, "--target", str(restored), "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")
        self.assertFalse((restored / "cache.ignored").exists())

    def test_writable_archive_parent_prevents_retirement(self):
        self.create()
        parent = self.output / "fixture__repository" / "unattributed"
        parent.mkdir(parents=True)
        parent.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "archive-path-externally-writable"):
            self.retire()
        self.assertTrue(self.target.exists())
        self.assertEqual(parent.stat().st_mode & 0o777, 0o777)
        report = cleanup_pass(self.store, self.cleanup_config(), self.output)
        result = report["results"][0]
        self.assertEqual(result["reason"], "archive-path-externally-writable")
        self.assertEqual(result["filesystem_path"], str(parent))
        self.assertEqual(result["path"], str(self.target))
        self.assertTrue(self.target.exists())

    def test_cleanup_resumes_private_generation_not_public_replacement(self):
        self.create()
        self.interrupt_after_move()
        self.target.mkdir()
        (self.target / "replacement").write_text("keep")
        result = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((result["retired"], result["failed"]), (1, 0))
        self.assertEqual((self.target / "replacement").read_text(), "keep")

    def open_pr_fixture(self):
        self.create()
        self.git("remote", "add", "origin", "https://example.invalid/fixture/repository.git")
        head = retirement._git("-C", str(self.target), "rev-parse", "HEAD")
        return [{"number": 1, "head": {"ref": "unrelated", "sha": head}}]

    def test_cleanup_pass_holds_tree_with_open_pull_request(self):
        prs = self.open_pr_fixture()
        config = self.cleanup_config()
        with patch.object(pull_requests, "open_pull_requests", return_value=prs) as lookup:
            report = cleanup_pass(self.store, config, self.output)
        self.assertEqual((report["retired"], report["held"], report["failed"]), (0, 1, 0))
        self.assertEqual(report["results"][0]["reason"], "open-pull-request")
        lookup.assert_called_once_with("fixture/repository")
        self.assertTrue((self.target / "work.txt").exists())
        self.assertEqual(list(self.output.iterdir()), [])
        # Once the PR is no longer open, normal retirement proceeds.
        with patch.object(pull_requests, "open_pull_requests", return_value=[]):
            report = cleanup_pass(self.store, config, self.output)
        self.assertEqual(report["retired"], 1)
        self.assertFalse(self.target.exists())

    def test_cleanup_pass_holds_when_pull_request_state_unavailable(self):
        self.open_pr_fixture()
        failure = subprocess.CalledProcessError(1, ["gh", "api"])
        with patch.object(pull_requests, "open_pull_requests", side_effect=failure):
            report = cleanup_pass(self.store, self.cleanup_config(), self.output)
        result = report["results"][0]
        self.assertEqual((report["held"], report["failed"]), (1, 0))
        self.assertEqual(result["reason"], "pull-request-state-unavailable")
        self.assertNotIn("quarantined", result)
        self.assertTrue(self.target.exists())

    def test_cleanup_pass_resumes_planned_retirement_despite_open_pull_request(self):
        prs = self.open_pr_fixture()
        self.interrupt_after_move()
        with patch.object(pull_requests, "open_pull_requests", return_value=prs) as lookup:
            report = cleanup_pass(self.store, self.cleanup_config(), self.output)
        self.assertEqual((report["retired"], report["failed"]), (1, 0))
        lookup.assert_not_called()

    def test_explicit_cleanup_accepts_registered_quiet_repository(self):
        self.create()
        config = self.cleanup_config(maintenance=False, pulse=False)
        report = cleanup_pass(self.store, config, self.output)
        self.assertEqual((report["retired"], report["held"]), (0, 1))
        self.assertEqual(report["results"][0]["status"], "outside-maintenance-scope")
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])
        result = cleanup_worktree(self.store, config, self.output, self.target)
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())
        restored = self.root / "restored"
        _helper("restore", result["archive"], "--target", str(restored), "--verification-copy")
        self.assertEqual((restored / "work.txt").read_text(), "unfinished result")

    def test_explicit_cleanup_still_requires_registered_nonlocal_repository(self):
        self.create()
        for settings in ({"local_only": True}, {"slug": "invalid"},
                         {"path": str(self.root / "unregistered")}):
            result = cleanup_worktree(
                self.store, self.cleanup_config(**settings), self.output, self.target,
            )
            self.assertEqual(result["status"], "outside-maintenance-scope")
            self.assertTrue(self.target.exists())
        config = self.root / "empty-repos.json"
        config.write_text(json.dumps({"initialized_repos": []}))
        result = cleanup_worktree(self.store, config, self.output, self.target)
        self.assertEqual(result["status"], "outside-maintenance-scope")
        self.assertTrue(self.target.exists())
        self.assertEqual(list(self.output.iterdir()), [])

    def test_enrolled_only_accepts_registered_quiet_repository(self):
        self.git("worktree", "add", "--detach", str(self.target), "HEAD")
        GenerationEnrollment(self.store).resolve(self.target, create=True)
        config = self.cleanup_config(maintenance=False, pulse=False)
        preview = retire_enrolled_only(
            self.store, config, self.output, self.target, False,
        )
        self.assertEqual(preview["status"], "enrolled-only-preview")
        result = retire_enrolled_only(
            self.store, config, self.output, self.target, True,
        )
        self.assertEqual(result["status"], "retired")
        self.assertFalse(self.target.exists())

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
