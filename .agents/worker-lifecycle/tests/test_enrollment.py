"""Disposable Git integration; intentionally outside the portable OS validator."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import errno
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess  # nosec B404 # owned Git and native processes in disposable fixtures
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.admission import AdmissionClosed, AdmissionRegistry
from worker_lifecycle.enrollment import GenerationEnrollment, MARKER, _git_directory
from worker_lifecycle.registry import main
from worker_lifecycle.storage import LifecycleRegistry, StoreConflict


class EnrollmentContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="generation-enrollment-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "repo"
        self.tree = self.root / "tree"
        self.git("init", "-q", str(self.repo))
        self.git("-C", str(self.repo), "commit", "-q", "--allow-empty", "-m", "fixture")
        self.git("-C", str(self.repo), "worktree", "add", "-q", "--detach", str(self.tree))
        self.store = LifecycleRegistry.initialize(self.root / "state")
        self.enrollment = GenerationEnrollment(self.store)
        self.marker = _git_directory(self.tree) / MARKER

    def git(self, *args):
        git = shutil.which("git")
        if git is None:
            self.fail("Git is required for enrollment integration")
        return subprocess.run(  # nosec B603 # resolved Git, fixed test operations, no shell
            [git, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args],
            check=True, capture_output=True, timeout=15,
            env={name: value for name, value in os.environ.items() if not name.startswith("GIT_")},
        )

    def test_replay_and_lookup_preserve_generation_without_new_events(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        before = self.store.summary()
        self.assertEqual(self.enrollment.resolve(self.tree, create=True), generation)
        self.assertEqual(self.enrollment.resolve(self.tree), generation)
        self.assertEqual(self.store.summary(), before)
        self.assertEqual(self.git("-C", str(self.tree), "status", "--porcelain").stdout, b"")

    @unittest.skipUnless(sys.platform == "linux", "Linux POSIX access ACL")
    def test_unsupported_posix_acl_query_does_not_prove_no_acl(self):
        directory = self.marker.parent
        directory.chmod(0o770)
        with patch("worker_lifecycle.enrollment._user_private_group", return_value=True):
            with patch("os.getxattr", side_effect=OSError(errno.ENOTSUP, "unsupported")):
                with self.assertRaisesRegex(ValueError, "not-shared-writable"):
                    _git_directory(self.tree)
                directory.chmod(0o700)
                self.assertEqual(_git_directory(self.tree), directory)
            directory.chmod(0o770)
            with patch("os.getxattr", side_effect=OSError(errno.ENODATA, "absent")):
                self.assertEqual(_git_directory(self.tree), directory)

    @unittest.skipUnless(sys.platform == "linux", "Linux POSIX access ACL")
    def test_private_group_write_requires_absent_access_acl(self):
        directory = self.marker.parent
        directory.chmod(0o770)
        with patch("worker_lifecycle.enrollment._user_private_group", return_value=True):
            self.assertEqual(_git_directory(self.tree), directory)
            with patch("os.getxattr", side_effect=OSError(errno.EACCES, "denied")):
                with self.assertRaisesRegex(ValueError, "not-shared-writable"):
                    _git_directory(self.tree)
            # Version 2 ACL: owner rwx, another UID rwx, owning group rwx,
            # mask rwx, other none. The mode alone still looks like 0770.
            entries = [(1, 7, 0xffffffff), (2, 7, os.getuid() + 1),
                       (4, 7, 0xffffffff), (16, 7, 0xffffffff), (32, 0, 0xffffffff)]
            acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *entry) for entry in entries)
            try:
                os.setxattr(directory, "system.posix_acl_access", acl)
            except OSError as error:
                if error.errno == errno.ENOTSUP:
                    self.skipTest("filesystem does not support POSIX ACLs")
                raise
            self.assertEqual(directory.stat().st_mode & 0o777, 0o770)
            with self.assertRaisesRegex(ValueError, "not-shared-writable"):
                _git_directory(self.tree)

    def test_enrollment_conflict_cli_includes_detail_without_changing_reason(self):
        self.enrollment.resolve(self.tree, create=True)
        self.marker.unlink()
        output = io.StringIO()
        with patch.object(sys, "argv", ["registry", "--state-dir", str(self.store.directory),
                                       "enroll", "--path", str(self.tree)]), redirect_stdout(output):
            self.assertEqual(main(), 2)
        result = json.loads(output.getvalue())
        self.assertEqual(result["reason"], "StoreConflict")
        self.assertEqual(result["detail"], "reserved-path-without-enrollment-marker")
        self.assertFalse(result["cleanup_authorized"])

    def test_git_query_treats_shell_metacharacters_as_path_data(self):
        path = self.root / "tree ; $(false) $HOME"
        self.git("-C", str(self.repo), "worktree", "add", "-q", "--detach", str(path))
        generation = self.enrollment.resolve(path, create=True)
        self.assertEqual(self.enrollment.resolve(path), generation)

    def test_git_fixture_is_independent_of_inherited_git_directory(self):
        with patch.dict(os.environ, {"GIT_DIR": str(self.root / "not-a-repository")}):
            result = self.git("-C", str(self.repo), "rev-parse", "--absolute-git-dir")
        self.assertEqual(Path(os.fsdecode(result.stdout).strip()), self.repo / ".git")

    def test_marker_format_two_records_directory_inodes(self):
        self.enrollment.resolve(self.tree, create=True)
        value = json.loads(self.marker.read_bytes())
        self.assertEqual(value["format"], 2)
        self.assertEqual(value["directory"], self.tree.stat().st_ino)
        self.assertEqual(value["git_identity"], self.marker.parent.stat().st_ino)

    def legacy_marker(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        value = json.loads(self.marker.read_bytes())
        value["format"] = 1
        value["directory"] = [self.tree.stat().st_dev + 1, value["directory"]]
        value["git_identity"] = [self.marker.parent.stat().st_dev + 1, value["git_identity"]]
        self.marker.write_text(json.dumps(value), encoding="utf-8")
        return generation, value

    def test_device_renumbering_recovery_preserves_marker_and_closed_gate(self):
        generation, _ = self.legacy_marker()
        saved = self.marker.read_bytes()
        self.assertEqual(self.enrollment.resolve(self.tree), generation)
        self.assertEqual(self.enrollment.resolve(self.tree, create=True), generation)
        self.assertEqual(self.marker.read_bytes(), saved)
        self.assertEqual(self.launch(self.tree).returncode, 0)
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        with self.assertRaises(AdmissionClosed):
            self.enrollment.resolve(self.tree, create=True)

    def test_device_recovery_rejects_changed_identity_and_invalid_formats(self):
        _, original = self.legacy_marker()
        changes = {
            "directory": [0, original["directory"][1] + 1],
            "git_identity": [0, original["git_identity"][1] + 1],
            "path": str(self.root), "git_directory": str(self.root),
            "installation_id": str(uuid4()), "format": True,
        }
        for field, replacement in changes.items():
            with self.subTest(field=field):
                value = dict(original, **{field: replacement})
                self.marker.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(StoreConflict):
                    self.enrollment.resolve(self.tree)
        self.marker.write_text(json.dumps(original), encoding="utf-8")
        (self.marker.parent / "gitdir").write_text("incorrect backlink\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            self.enrollment.resolve(self.tree)

    def test_interruption_between_marker_and_transaction_is_recoverable(self):
        with patch.object(AdmissionRegistry, "open_generation", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.enrollment.resolve(self.tree, create=True)
        before = self.marker.read_bytes()
        with self.assertRaises(AdmissionClosed):
            self.enrollment.resolve(self.tree)
        generation = self.enrollment.resolve(self.tree, create=True)
        self.assertEqual(self.marker.read_bytes(), before)
        self.assertEqual(self.enrollment.resolve(self.tree), generation)

    def test_closed_admission_cannot_be_reopened(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        before = self.store.summary()
        with self.assertRaises(AdmissionClosed):
            self.enrollment.resolve(self.tree, create=True)
        self.assertEqual(self.store.summary(), before)

    def test_replaced_directory_with_copied_git_pointer_is_rejected(self):
        self.enrollment.resolve(self.tree, create=True)
        pointer = (self.tree / ".git").read_bytes()
        self.tree.rename(self.root / "original")
        self.tree.mkdir()
        (self.tree / ".git").write_bytes(pointer)
        with self.assertRaises(StoreConflict):
            self.enrollment.resolve(self.tree, create=True)

    def test_other_installation_and_canonical_checkout_are_rejected(self):
        self.enrollment.resolve(self.tree, create=True)
        other = GenerationEnrollment(LifecycleRegistry.initialize(self.root / "other"))
        with self.assertRaises(StoreConflict):
            other.resolve(self.tree, create=True)
        with self.assertRaises(ValueError):
            self.enrollment.resolve(self.repo, create=True)

    def test_invalid_marker_is_preserved_not_replaced(self):
        self.marker.write_bytes(b"broken")
        self.marker.chmod(0o600)
        with self.assertRaises(ValueError):
            self.enrollment.resolve(self.tree, create=True)
        self.assertEqual(self.marker.read_bytes(), b"broken")

    def test_missing_marker_cannot_rebind_reserved_path(self):
        self.enrollment.resolve(self.tree, create=True)
        self.marker.unlink()
        with self.assertRaises(StoreConflict):
            self.enrollment.resolve(self.tree, create=True)
        self.assertFalse(self.marker.exists())

    def test_concurrent_creators_converge(self):
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(self.enrollment.resolve, self.tree, create=True) for _ in range(4)]
            self.assertEqual(len({future.result() for future in futures}), 1)

    def test_publication_link_left_by_crash_is_recoverable(self):
        with patch.object(AdmissionRegistry, "open_generation", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.enrollment.resolve(self.tree, create=True)
        os.link(self.marker, self.marker.parent / ".interrupted-publish.tmp")
        self.assertEqual(self.enrollment.resolve(self.tree, create=True), self.enrollment.resolve(self.tree))

    def launch(self, path, *, cwd=None, sentinel=None):
        entry = Path(__file__).resolve().parents[1] / "worker-launch.py"
        return subprocess.run(  # nosec B603 # fixed Python entry point and disposable marker command
            [sys.executable, "-E", "-s", "-B", str(entry), "--initialize",
             "--state-dir", str(self.store.directory), "--worktree", str(path),
             "--", "touch", str(sentinel or path / "executed")],
            cwd=cwd or path, capture_output=True, text=True, timeout=30,
        )

    def test_missing_registered_path_cannot_fall_back_to_observation(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        before = self.store.summary()
        self.tree.rename(self.root / "moved")
        sentinel = self.root / "executed"
        result = self.launch(self.tree, cwd=self.root, sentinel=sentinel)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.store.summary(), before)

    def test_replaced_registered_path_cannot_fall_back_to_observation(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        before = self.store.summary()
        self.tree.rename(self.root / "moved")
        self.tree.symlink_to(self.repo, target_is_directory=True)
        sentinel = self.root / "executed"
        result = self.launch(self.tree, cwd=self.root, sentinel=sentinel)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.store.summary(), before)

    def test_unreserved_alias_uses_canonical_generation(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        alias = self.root / "alias"
        alias.symlink_to(self.tree, target_is_directory=True)
        result = self.launch(alias)
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT generation_id FROM bindings").fetchone()[0], generation)

    def test_nested_launcher_gets_a_fresh_admission_attempt(self):
        """A nested launcher admits a new attempt, not its parent's run ID."""
        generation = self.enrollment.resolve(self.tree, create=True)
        scripts = Path(__file__).resolve().parents[2] / "scripts"
        launcher = scripts / "sandbox-exec-helper.sh"
        entry = Path(__file__).resolve().parents[1] / "worker-launch.py"
        run = str(uuid4())
        env = {
            name: value for name, value in os.environ.items()
            if not name.startswith("AIDEVOPS_")
        }
        env.update(
            HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / "config"),
            AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
            AIDEVOPS_LIFECYCLE_WORKTREE=str(self.tree),
            AIDEVOPS_LIFECYCLE_GENERATION_ID=generation,
            AIDEVOPS_LIFECYCLE_RUN_ID=run,
        )
        sentinel = self.tree / "executed"
        # Fixed nested launcher argv and a locally generated UUID, not env input.
        result = subprocess.run(  # noqa: S603  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(entry),
             "--state-dir", str(self.store.directory),
             "--worktree", str(self.tree), "--generation-id", generation,
             "--run-id", run, "--",
             "bash", str(launcher), "run", "touch", str(sentinel)],
            cwd=self.tree, env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(sentinel.exists())
        with self.store.connection() as connection:
            rows = connection.execute(
                "SELECT run_id,generation_id FROM bindings"
            ).fetchall()
        self.assertEqual(len({row[0] for row in rows}), 2)
        self.assertEqual({row[1] for row in rows}, {generation})

    def test_creation_hook_and_automatic_launch_share_generation(self):
        scripts = Path(__file__).resolve().parents[2] / "scripts"
        created = self.root / "created"
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("AIDEVOPS_", "GIT_", "WORKTREE_"))}
        env.update(HOME=str(self.root), AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory),
                   GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.hooksPath", GIT_CONFIG_VALUE_0="/dev/null")
        bash = shutil.which("bash")
        if bash is None:
            self.fail("Bash is required for creation-hook integration")
        result = subprocess.run(  # nosec B603 # constant shell program; paths passed as quoted positional argv
            [bash, "-c", 'source "$1/shared-constants.sh" && source "$1/shared-worktree-create.sh" '
             '&& worktree_create_registered "$2" "$3" HEAD --detach',
             "fixture", str(scripts), str(self.repo), str(created)],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=40,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        generation = self.enrollment.resolve(created)
        result = self.launch(created)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((created / "executed").exists())
        with self.store.connection() as connection:
            bindings = connection.execute("SELECT generation_id FROM bindings").fetchall()
            self.assertEqual([row[0] for row in bindings], [generation])

    def creation_enrollment(self, path):
        scripts = Path(__file__).resolve().parents[2] / "scripts"
        env = {name: value for name, value in os.environ.items()
               if not name.startswith(("GIT_", "AIDEVOPS_", "WORKTREE_"))}
        env.update(HOME=str(self.root), AIDEVOPS_LIFECYCLE_STATE_DIR=str(self.store.directory))
        bash = shutil.which("bash")
        if bash is None:
            self.fail("Bash is required for enrollment diagnostics")
        return subprocess.run(  # nosec B603 # fixed Bash program and disposable fixture paths
            [bash, "-e", "-c", 'source "$1/shared-worktree-create.sh"; _worktree_enroll_generation "$2"',
             "fixture", str(scripts), str(path)],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=30,
        )

    def test_schema_one_creation_reports_gap_without_migration(self):
        with self.store.connection(write=True) as connection:
            connection.execute("DROP TABLE generation_admissions")
            connection.execute("PRAGMA user_version=1")
        before = self.store.summary()
        result = self.creation_enrollment(self.tree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("coverage-gap: schema-upgrade-required", result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.store.summary(), before)
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
        with self.assertRaises(ValueError):
            self.enrollment.resolve(self.tree, create=True)

    def test_schema_one_compatibility_refuses_existing_marker(self):
        self.enrollment.resolve(self.tree, create=True)
        saved = self.marker.read_bytes()
        with self.store.connection(write=True) as connection:
            connection.execute("DROP TABLE generation_admissions")
            connection.execute("PRAGMA user_version=1")
        result = self.creation_enrollment(self.tree)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Generation enrollment refused", result.stderr)
        self.assertEqual(self.marker.read_bytes(), saved)

    def test_schema_one_compatibility_refuses_admission_state(self):
        with self.store.connection(write=True) as connection:
            connection.execute("PRAGMA user_version=1")
        result = self.creation_enrollment(self.tree)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.marker.exists())

    def test_enrollment_failure_diagnostic_survives_errexit(self):
        result = self.creation_enrollment(self.repo)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        detail = json.loads(result.stderr.removeprefix("Generation enrollment refused: "))
        self.assertEqual(detail["reason"], "ValueError")
        self.assertFalse(detail["cleanup_authorized"])

    def test_automatic_launch_cannot_bypass_closed_or_damaged_enrollment(self):
        generation = self.enrollment.resolve(self.tree, create=True)
        saved = self.marker.read_bytes()
        self.marker.write_bytes(b"invalid")
        result = self.launch(self.tree)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((self.tree / "executed").exists())
        self.marker.write_bytes(saved)
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        result = self.launch(self.tree)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((self.tree / "executed").exists())


if __name__ == "__main__":
    unittest.main()
