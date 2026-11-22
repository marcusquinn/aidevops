"""Portable native-Git creation and exclusive-publication qualification."""

import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # owned disposable repositories and native processes
import sys
import tempfile
import unittest

from worker_lifecycle.cleanup_plan import prepare_cleanup
from worker_lifecycle.creation import WorktreeSpec, create_worktree
from worker_lifecycle.storage import LifecycleRegistry


class CreationContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lifecycle-creation-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "repository"
        self.target = self.root / "new worktree"
        self.store = LifecycleRegistry.initialize(self.root / "state")
        git = shutil.which("git")
        if git is None:
            self.fail("Git is required for controlled-creation qualification")
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        for arguments in (
            ["init", "-q", str(self.repo)],
            ["-C", str(self.repo), "config", "core.hooksPath", "/dev/null"],
            ["-C", str(self.repo), "-c", "user.name=Fixture", "-c",
             "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty",
             "-m", "fixture"],
        ):
            subprocess.run(  # nosec B603 # fixed setup in a disposable repository
                [git, *arguments], check=True, capture_output=True, timeout=15,
                env=environment,
            )

    def test_creator_exit_allows_closed_preparation(self):
        program = (
            "import os,sys; from pathlib import Path; "
            "from worker_lifecycle.creation import WorktreeSpec, create_worktree; "
            "from worker_lifecycle.storage import LifecycleRegistry; "
            "create_worktree(LifecycleRegistry(Path(sys.argv[1])), "
            "WorktreeSpec(Path(sys.argv[2]), Path(sys.argv[3]), 'HEAD', ('--detach',)), "
            "os.getpid(), 'owned-creator')"
        )
        subprocess.run(  # nosec B603 # fixed creator program; fixture paths are argv
            [sys.executable, "-E", "-s", "-B", "-c", program,
             str(self.store.directory), str(self.repo), str(self.target)],
            cwd=Path(__file__).resolve().parents[1],
            check=True, capture_output=True, timeout=30,
        )
        prepared = prepare_cleanup(self.store, self.target)
        self.assertTrue(prepared["creation_verified"])
        self.assertEqual(prepared["status"], "registered-runs-ended")
        self.assertEqual(prepared["admission"], "closed")
        self.assertFalse(prepared["cleanup_authorized"])
        self.assertTrue(self.target.is_dir())

    def test_publication_does_not_replace_existing_directory(self):
        self.target.mkdir()
        before = self.target.stat()
        with self.assertRaises(FileExistsError):
            create_worktree(
                self.store, WorktreeSpec(self.repo, self.target, "HEAD", ("--detach",)),
                os.getpid(), "owned-creator",
            )
        self.assertEqual(self.target.stat().st_ino, before.st_ino)
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertEqual(self.store.summary()["events"], 0)
