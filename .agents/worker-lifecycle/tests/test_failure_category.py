"""Sanitized failure categories for registry contention, schema, capacity and permission."""

import argparse
from contextlib import nullcontext, redirect_stderr
import errno
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from worker_lifecycle import launch
from worker_lifecycle.cleanup import _failure_details
from worker_lifecycle.cli_errors import error_details
from worker_lifecycle.filesystem import FilesystemValidationError, validate_private_path
from worker_lifecycle.refusal import failure_category
from worker_lifecycle.storage import LifecycleRegistry, StoreCapacity


class FailureCategory(unittest.TestCase):
    def test_labels(self):
        cases = (
            (sqlite3.OperationalError("database is locked"), "contention"),
            (BlockingIOError(11, "busy"), "contention"),
            (sqlite3.OperationalError("no such table: runs"), "schema"),
            (ValueError("unsupported-store-schema"), "schema"),
            (sqlite3.OperationalError("database or disk is full"), "capacity"),
            (StoreCapacity("journal-event-limit-reached"), "capacity"),
            (ValueError("invalid-event-limit"), None),
            (sqlite3.OperationalError("attempt to write a readonly database"), "permission"),
            (PermissionError(13, "denied"), "permission"),
            (RuntimeError("anything"), None),
        )
        for error, label in cases:
            with self.subTest(error=repr(error)):
                self.assertEqual(failure_category(error), label)

    def test_invalid_event_limit_is_not_exhaustion(self):
        with tempfile.TemporaryDirectory() as name:
            with self.assertRaisesRegex(ValueError, "invalid-event-limit") as caught:
                LifecycleRegistry.initialize(Path(name) / "state", max_events=0)
            self.assertIsNone(failure_category(caught.exception))

    def test_wrapped_filesystem_categories_reach_cli_and_cleanup(self):
        path = Path("/private-state")
        for number, category in ((errno.EACCES, "permission"), (errno.ENOSPC, "capacity")):
            with self.subTest(errno=number):
                with patch("worker_lifecycle.filesystem.os.open", side_effect=OSError(number, "private text")):
                    with self.assertRaises(FilesystemValidationError) as caught:
                        validate_private_path(path)
                error = caught.exception
                self.assertEqual(failure_category(error), category)
                for details in (_failure_details(error), error_details(error, "cleanup")):
                    self.assertEqual(details["category"], category)
                    self.assertEqual(details["errno"], number)
                    self.assertEqual(details["reason"], "filesystem-path-unavailable")
                    self.assertEqual(details["filesystem_path"], str(path))
                    self.assertNotIn("private text", repr(details))

    def test_launch_sqlite_diagnostics_preserve_execution_policy(self):
        error = sqlite3.OperationalError("database is locked: private text")
        args = argparse.Namespace(state_dir=Path("state"), worktree=Path("worktree"), initialize=False)
        expected = "reason=OperationalError code=database-locked category=contention"
        for target in ("require_unregistered", "enrolled_generation", "DirectoryHandle", "record"):
            enrollment = (patch.object(launch, "enrolled_generation", return_value=None)
                          if target == "record" else nullcontext())
            with self.subTest(target=target), patch.object(launch, target, side_effect=error), \
                    patch.object(launch, "execute", return_value=9) as execute, \
                    enrollment, redirect_stderr(io.StringIO()) as stderr:
                if target == "require_unregistered":
                    argv = ["launch", "--state-dir", "state", "--worktree", "worktree",
                            "--unregistered-only", "--", "native"]
                    with patch("sys.argv", argv):
                        result = launch.main()
                elif target == "DirectoryHandle":
                    result = launch.run_admitted(args.state_dir, args.worktree, "run", "generation", ["native"])
                else:
                    result = launch._run_observed(args, ["native"])
                self.assertIn(expected, stderr.getvalue())
                self.assertNotIn("private text", stderr.getvalue())
                if target == "record":
                    self.assertEqual(result, 9)
                    execute.assert_called_once()
                else:
                    self.assertEqual(result, 75)
                    execute.assert_not_called()

    def test_cleanup_and_cli_details_never_carry_message_text(self):
        private_message = "/private/path/SELECT private_column FROM runs"
        error = sqlite3.OperationalError("database is locked: " + private_message)
        for details in (_failure_details(error), error_details(error, "cleanup")):
            self.assertEqual(details["category"], "contention")
            self.assertNotIn(private_message, repr(details))
        self.assertEqual(error_details(error, "cleanup")["detail"], "database-locked")

    def test_live_lock_contention_is_refused_and_recovers(self):
        with tempfile.TemporaryDirectory(prefix="lifecycle-category-") as name:
            store = LifecycleRegistry.initialize(Path(name).resolve() / "state")
            holder = sqlite3.connect(store.path, isolation_level=None)
            holder.execute("BEGIN IMMEDIATE")
            try:
                with self.assertRaises(sqlite3.OperationalError) as caught:
                    with store.connection(write=True):
                        pass
                self.assertEqual(failure_category(caught.exception), "contention")
            finally:
                holder.rollback()
                holder.close()
            with store.connection(write=True):
                pass


if __name__ == "__main__":
    unittest.main()
