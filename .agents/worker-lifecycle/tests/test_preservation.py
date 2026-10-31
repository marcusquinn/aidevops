"""Qualify archive payload mechanics, not legacy lifecycle or cleanup authority.

Requires the repository's Git/Bash archive backend; deliberately excluded from
the standalone standard-library validator. Only disposable repositories are used.
"""

import os
from pathlib import Path
import subprocess  # nosec B404 # fixed Git/archive operations in disposable repositories
import tempfile
import unittest


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

    def command(self, *args, check=True):
        result = subprocess.run([str(arg) for arg in args], env=self.env, capture_output=True, timeout=60)  # nosec B603 # test-owned argv, no shell interpolation
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def git(self, directory, *args):
        return self.command("git", "-C", directory, *args).stdout

    def helper(self, *args, check=True):
        return self.command("bash", HELPER, *args, check=check)

    def archive(self):
        result = self.helper("archive", self.work, "--repo", "fixture/repository",
                             "--issue", "1", "--reason", "failed-worker", "--base-branch", "develop",
                             "--output-root", self.root / "archives")
        return Path(os.fsdecode(result.stdout).strip())

    def restore(self, archive, *, check=True):
        target = self.root / "restored"
        result = self.helper("restore", archive, "--target", target, "--verification-copy", check=check)
        return target, result

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

    def test_backend_omits_ignored_data_so_it_is_not_full_preservation(self):
        ignored = self.work / "important.ignored"
        ignored.write_bytes(b"unique local configuration\n")
        archive = self.archive()
        target, _ = self.restore(archive)
        self.assertFalse((target / ignored.name).exists())
        self.assertEqual(ignored.read_bytes(), b"unique local configuration\n")
        # Passing this test records a blocker, NOT permission to discard ignored files.


if __name__ == "__main__":
    unittest.main()
