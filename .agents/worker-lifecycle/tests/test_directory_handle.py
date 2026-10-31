"""Native path replacement tests in disposable directories only."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from worker_lifecycle.directory_handle import DirectoryHandle


class DirectoryHandleContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / "worktree"
        self.path.mkdir()

    def test_stable_directory_and_closed_handle(self):
        with DirectoryHandle(self.path) as handle:
            self.assertTrue(handle.matches_path())
        self.assertFalse(handle.matches_path())
        handle.close()  # Closing twice must not close a subsequently reused FD.

    def test_replacement_directory_at_same_path_is_not_original(self):
        with DirectoryHandle(self.path) as handle:
            self.path.rename(self.root / "original")
            self.path.mkdir()
            self.assertFalse(handle.matches_path())

    def test_missing_directory_invalidates_handle(self):
        with DirectoryHandle(self.path) as handle:
            self.path.rmdir()
            self.assertFalse(handle.matches_path())

    def test_observed_mismatch_never_resurrects(self):
        with DirectoryHandle(self.path) as handle:
            moved = self.root / "original"
            self.path.rename(moved)
            self.assertFalse(handle.matches_path())
            moved.rename(self.path)
            self.assertFalse(handle.matches_path())

    def test_symlink_to_original_does_not_restore_match(self):
        with DirectoryHandle(self.path) as handle:
            moved = self.root / "original"
            self.path.rename(moved)
            self.path.symlink_to(moved, target_is_directory=True)
            self.assertFalse(handle.matches_path())

    def test_symlink_capture_is_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.path, target_is_directory=True)
        with self.assertRaises(ValueError):
            DirectoryHandle(alias)

    def test_permission_failure_is_not_a_match(self):
        with DirectoryHandle(self.path) as handle:
            with patch.object(Path, "stat", side_effect=PermissionError):
                self.assertFalse(handle.matches_path())
            self.assertFalse(handle.matches_path())

    def test_different_process_cannot_reuse_observation(self):
        with DirectoryHandle(self.path) as handle:
            with patch("worker_lifecycle.directory_handle.os.getpid", return_value=os.getpid() + 1):
                self.assertFalse(handle.matches_path())

    def test_contents_can_change_without_directory_identity_changing(self):
        with DirectoryHandle(self.path) as handle:
            (self.path / "new-work").write_text("not archived")
            self.assertTrue(handle.matches_path())
            # Deliberately demonstrates why this alone never permits cleanup.


if __name__ == "__main__":
    unittest.main()
