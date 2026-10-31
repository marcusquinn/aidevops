"""Qualify archive payload mechanics, not legacy lifecycle or cleanup authority.

Requires the Git/Bash archive backend included in the portable registry validator.
Only disposable repositories are used.
"""

import json
import os
from pathlib import Path
import stat
import subprocess  # nosec B404 # fixed Git/archive operations in disposable repositories
import sys
import tarfile
import tempfile
import unittest

from worker_lifecycle.enrollment import GenerationEnrollment
from worker_lifecycle.storage import LifecycleRegistry


HELPER = Path(__file__).resolve().parents[2] / "scripts" / "worktree-archive-helper.sh"


class PreservationContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="preservation-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.work = self.root / "work"
        self.marker = self.root / "legacy-state-must-not-be-used"
        self.marker.write_text("not a lifecycle database")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(
            HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / "config"),
            GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
            GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_EMAIL="fixture@example.invalid",
            AIDEVOPS_WORKTREE_RECOVERY_POLICY="git-only",
            AIDEVOPS_WORKTREE_BASE_DIR=str(self.root),
            AIDEVOPS_RECOVERY_TIMING_LOG=str(self.root / "timing.jsonl"),
            WORKTREE_REGISTRY_DB=str(self.marker), WORKTREE_REGISTRY_DIR=str(self.root / "unused-registry"),
            PYTHONDONTWRITEBYTECODE="1", LC_ALL="C",
        )
        self.command("git", "init", "-q", "--initial-branch=develop", self.repo)
        (self.repo / "mixed").write_bytes(b"base\n")
        (self.repo / "binary").write_bytes(b"\x00\xffbase")
        (self.repo / ".gitignore").write_text("*.ignored\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-qm", "base")
        self.git(self.repo, "worktree", "add", "-qb", "fixture/local", self.work)
        (self.work / "local-commit").write_bytes(b"only local\n")
        self.git(self.work, "add", "local-commit")
        self.git(self.work, "commit", "-qm", "unpublished work")

    def command(self, *args, check=True, umask=-1):
        result = subprocess.run(  # nosec B603 # test-owned argv, no shell interpolation
            [str(arg) for arg in args], env=self.env, capture_output=True,
            timeout=60, umask=umask,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def git(self, directory, *args):
        return self.command("git", "-C", directory, *args).stdout

    def helper(self, *args, check=True, umask=-1):
        return self.command("bash", HELPER, *args, check=check, umask=umask)

    def archive(self):
        result = self.helper("archive", self.work, "--repo", "fixture/repository",
                             "--issue", "1", "--reason", "failed-worker", "--base-branch", "develop",
                             "--output-root", self.root / "archives")
        return Path(os.fsdecode(result.stdout).strip())

    def restore(self, archive, *, check=True):
        target = self.root / "restored"
        result = self.helper("restore", archive, "--target", target, "--verification-copy", check=check)
        return target, result

    def test_tar_metadata_survives_different_creation_and_restore_umasks(self):
        masks = (0o022, 0o077, 0o002)
        modes, links = {}, {}
        program = (
            "import os,sys; from pathlib import Path; root=Path(sys.argv[1]); "
            "os.symlink('mixed',root/sys.argv[2]); "
            "os.symlink('absent',root/sys.argv[3]); "
            "(root/sys.argv[4]).write_bytes(b'payload\\n')"
        )
        for mask in masks:
            names = [f"{kind}-{mask:o}" for kind in ("link", "dangling", "file")]
            self.command(sys.executable, "-c", program, self.work, *names, umask=mask)
            for name in names:
                path = self.work / name
                modes[name] = stat.S_IMODE(path.lstat().st_mode)
                if path.is_symlink():
                    links[name] = os.readlink(path)
        archive = self.archive()
        manifest = json.loads((archive / "manifest.json").read_text())
        self.assertTrue(manifest["source_fingerprint"]["untracked_symlink_modes"])
        with tarfile.open(archive / "untracked.tar.gz") as payload:
            for name, mode in modes.items():
                self.assertEqual(payload.getmember(name).mode, mode)
        self.helper("verify", archive)
        original_target_mode = stat.S_IMODE((self.work / "mixed").stat().st_mode)
        for mask in masks:
            target = self.root / f"restored-{mask:o}"
            self.helper("restore", archive, "--target", target,
                        "--verification-copy", umask=mask)
            restored = json.loads(self.command(
                sys.executable, HELPER.with_name("worktree_archive_snapshot.py"),
                "--git-only", target,
            ).stdout)
            self.assertEqual(restored, manifest["source_fingerprint"])
            for name, mode in modes.items():
                self.assertEqual(stat.S_IMODE((target / name).lstat().st_mode), mode)
                self.assertEqual(stat.S_IMODE((self.work / name).lstat().st_mode), mode)
                if name in links:
                    self.assertTrue((target / name).is_symlink())
                    self.assertEqual(os.readlink(target / name), links[name])
                else:
                    self.assertEqual((target / name).read_bytes(), b"payload\n")
            # Git restores the tracked target; symlink chmod must not touch it.
            self.assertEqual(stat.S_IMODE((target / "mixed").stat().st_mode) & 0o111, 0)
            self.assertEqual(stat.S_IMODE((self.work / "mixed").stat().st_mode),
                             original_target_mode)

    def test_unpublished_commit_index_working_files_and_links_round_trip(self):
        (self.work / "mixed").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed")
        (self.work / "mixed").write_bytes(b"unstaged\n")
        (self.work / "binary").write_bytes(b"\x00\xffchanged")
        (self.work / "new file\nwith newline").write_bytes(b"untracked\n")
        (self.work / "link").symlink_to("mixed")
        head = self.git(self.work, "rev-parse", "HEAD")
        staged = self.git(self.work, "diff", "--cached", "--binary")
        unstaged = self.git(self.work, "diff", "--binary")
        archive = self.archive()
        self.helper("verify", archive)
        # Leave the source data intact, but unavailable at the captured worktree path.
        self.work.rename(self.root / "retained-source")
        target, _ = self.restore(archive)
        self.assertEqual(self.git(target, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(target, "diff", "--cached", "--binary"), staged)
        self.assertEqual(self.git(target, "diff", "--binary"), unstaged)
        self.assertEqual((target / "local-commit").read_bytes(), b"only local\n")
        self.assertEqual((target / "new file\nwith newline").read_bytes(), b"untracked\n")
        self.assertEqual(os.readlink(target / "link"), "mixed")
        self.git(target, "fsck", "--connectivity-only")
        self.assertEqual(self.marker.read_text(), "not a lifecycle database")
        self.assertFalse((self.root / "unused-registry").exists())

    def test_corrupt_archive_is_refused_and_source_stays(self):
        (self.work / "mixed").write_bytes(b"unique work\n")
        archive = self.archive()
        with (archive / "diff.patch").open("ab") as stream:
            stream.write(b"corruption")
        self.assertNotEqual(self.helper("verify", archive, check=False).returncode, 0)
        target, result = self.restore(archive, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())
        self.assertEqual((self.work / "mixed").read_bytes(), b"unique work\n")

    def test_late_source_change_invalidates_snapshot(self):
        archive = self.archive()
        (self.work / "mixed").write_bytes(b"late change\n")
        result = self.helper("source-matches", archive, self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.work / "mixed").read_bytes(), b"late change\n")

    def test_registry_cli_preserves_and_rechecks_real_wip_without_ignored_data(self):
        store = LifecycleRegistry.initialize(self.root / "state")
        GenerationEnrollment(store).resolve(self.work, create=True)
        entry = Path(__file__).resolve().parents[1]
        self.command(sys.executable, "-E", "-s", "-B", entry / "worker-launch.py",
                     "--state-dir", store.directory, "--worktree", self.work,
                     "--", "touch", self.work / "worker-result")
        (self.work / "mixed").write_bytes(b"staged result\n")
        self.git(self.work, "add", "mixed")
        (self.work / "mixed").write_bytes(b"unstaged result\n")
        (self.work / "private.ignored").write_bytes(b"private fixture; do not archive\n")
        output = self.root / "verified-archives"
        output.mkdir(mode=0o700)
        command = (sys.executable, "-E", "-s", "-B", entry / "worker-registry.py",
                   "--state-dir", store.directory, "preserve-wip", "--path", self.work,
                   "--repo", "fixture/repository", "--base-branch", "develop",
                   "--output-root", output)
        report = json.loads(self.command(*command).stdout)
        self.assertEqual(report["status"], "wip-archive-verified")
        self.assertFalse(report["cleanup_authorized"])
        self.assertTrue(report["common_repository_required"])
        before = store.summary()
        self.assertEqual(json.loads(self.command(*command).stdout), report)
        self.assertEqual(store.summary(), before)
        archive = Path(report["archive"])
        restored, _ = self.restore(archive)
        self.assertEqual(self.git(restored, "diff", "--cached", "--binary"),
                         self.git(self.work, "diff", "--cached", "--binary"))
        self.assertEqual(self.git(restored, "diff", "--binary"),
                         self.git(self.work, "diff", "--binary"))
        self.assertTrue((restored / "worker-result").exists())
        self.assertFalse((restored / "private.ignored").exists())
        self.assertTrue((self.work / "private.ignored").exists())
        self.assertEqual(self.marker.read_text(), "not a lifecycle database")
        self.assertFalse((self.root / "unused-registry").exists())
        with (archive / "diff.patch").open("ab") as stream:
            stream.write(b"corruption")
        self.assertEqual(self.command(*command, check=False).returncode, 2)
        self.assertEqual((self.work / "mixed").read_bytes(), b"unstaged result\n")
        self.assertEqual(store.summary(), before)

    def test_pinned_base_restores_after_fixture_worktree_branch_and_reflog_removal(self):
        store = LifecycleRegistry.initialize(self.root / "state")
        GenerationEnrollment(store).resolve(self.work, create=True)
        entry = Path(__file__).resolve().parents[1]
        self.command(sys.executable, "-E", "-s", "-B", entry / "worker-launch.py",
                     "--state-dir", store.directory, "--worktree", self.work,
                     "--", "touch", self.work / "worker-result")
        output = self.root / "verified-archives"
        output.mkdir(mode=0o700)
        head = self.git(self.work, "rev-parse", "HEAD")
        base = self.git(self.repo, "rev-parse", "develop")
        report = json.loads(self.command(
            sys.executable, "-E", "-s", "-B", entry / "worker-registry.py",
            "--state-dir", store.directory, "preserve-wip", "--path", self.work,
            "--repo", "fixture/repository", "--base-branch", "develop",
            "--output-root", output,
        ).stdout)
        self.assertEqual(self.git(self.repo, "rev-parse", report["base_ref"]), base)
        # Only this test's disposable repository is modified or garbage-collected.
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        self.git(self.repo, "checkout", "--orphan", "replacement")
        self.git(self.repo, "commit", "-qm", "replacement root")
        self.git(self.repo, "branch", "-D", "develop", "fixture/local")
        self.git(self.repo, "reflog", "expire", "--expire=now", "--all")
        self.git(self.repo, "gc", "--prune=now")
        self.assertNotEqual(self.command(
            "git", "-C", self.repo, "cat-file", "-e", head.decode().strip(), check=False,
        ).returncode, 0)
        restored, _ = self.restore(Path(report["archive"]))
        self.assertEqual(self.git(restored, "rev-parse", "HEAD"), head)
        self.assertEqual((restored / "local-commit").read_bytes(), b"only local\n")
        self.assertTrue((restored / "worker-result").exists())

    def test_wip_archive_excludes_ignored_files(self):
        """Honor the ignore policy without changing the original local files."""
        ignored = self.work / "important.ignored"
        ignored.write_bytes(b"unique local configuration\n")
        archive = self.archive()
        target, _ = self.restore(archive)
        self.assertFalse((target / ignored.name).exists())
        self.assertEqual(ignored.read_bytes(), b"unique local configuration\n")


if __name__ == "__main__":
    unittest.main()
