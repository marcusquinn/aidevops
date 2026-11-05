"""Sanitized failure categories for registry contention, schema, capacity and permission."""

from pathlib import Path
import sqlite3
import tempfile
import unittest

from worker_lifecycle.cleanup import _failure_details
from worker_lifecycle.cli_errors import error_details
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
            (sqlite3.OperationalError("attempt to write a readonly database"), "permission"),
            (PermissionError(13, "denied"), "permission"),
            (RuntimeError("anything"), None),
        )
        for error, label in cases:
            with self.subTest(error=repr(error)):
                self.assertEqual(failure_category(error), label)

    def test_cleanup_and_cli_details_never_carry_message_text(self):
        secret = "/private/path/SELECT secret FROM runs"
        error = sqlite3.OperationalError("database is locked: " + secret)
        for details in (_failure_details(error), error_details(error, "cleanup")):
            self.assertEqual(details["category"], "contention")
            self.assertNotIn("secret", repr(details))
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
