"""Filesystem policies and operator diagnostics on disposable local state."""

import errno
import json
import os
from pathlib import Path
import subprocess  # nosec B404 # real CLI in disposable state, fixed argv
import sys
import tempfile
import unittest
from unittest.mock import patch

from worker_lifecycle.cleanup import _failure_details
from worker_lifecycle.filesystem import (
    FilesystemValidationError, checked_directory, filesystem_error_details,
    validate_private_path,
)
from worker_lifecycle.storage import LifecycleRegistry, _private


class FilesystemContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.state = self.root / "state"
        self.store = LifecycleRegistry.initialize(self.state)

    def test_private_leaf_does_not_require_private_ancestors(self):
        self.root.chmod(0o755)
        validate_private_path(self.state, directory=True)
        validate_private_path(self.store.path)
        _private(self.store.path)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_initialization_refuses_unsafe_parent_before_creating_state(self):
        self.root.chmod(0o777)
        target = self.root / "new-state"
        with self.assertRaisesRegex(FilesystemValidationError, "externally-writable"):
            LifecycleRegistry.initialize(target)
        self.assertFalse(target.exists())

    def test_private_file_violation_has_legacy_reason_and_separate_context(self):
        self.store.path.chmod(0o644)
        with self.assertRaises(FilesystemValidationError) as raised:
            validate_private_path(self.store.path)
        self.assertEqual(filesystem_error_details(raised.exception), {
            "reason": "state-path-must-be-private-and-owned",
            "filesystem_path": str(self.store.path),
            "filesystem_violation": "not-private",
        })
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o644)

    def test_wrong_type_and_final_symlink_are_not_followed(self):
        link = self.root / "link"
        link.symlink_to(self.store.path)
        for path in (self.state, link):
            with self.assertRaises(FilesystemValidationError) as raised:
                validate_private_path(path)
            self.assertEqual(raised.exception.violation, "wrong-type")

    def test_untrusted_ancestor_and_parent_symlink_are_refused(self):
        self.root.chmod(0o777)
        with self.assertRaisesRegex(FilesystemValidationError, "externally-writable"):
            LifecycleRegistry(self.state)
        self.root.chmod(0o700)
        alias = self.root / "alias"
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(FilesystemValidationError) as raised:
            validate_private_path(alias / "registry.sqlite3")
        self.assertEqual(raised.exception.path, alias)
        self.assertIn("errno", filesystem_error_details(raised.exception))

    def test_absence_and_parent_traversal_contracts(self):
        for path in (self.state / "absent", self.root / "absent" / "nested"):
            with self.assertRaises(FileNotFoundError):
                validate_private_path(path)
        with self.assertRaisesRegex(FilesystemValidationError, "invalid-filesystem-path"):
            validate_private_path(self.state / "..", directory=True)

    def test_wrong_owner_and_sticky_ancestor_rules(self):
        with patch("worker_lifecycle.filesystem.os.getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(FilesystemValidationError, "wrong-owner"):
                validate_private_path(self.store.path)
        self.root.chmod(0o1777)
        validate_private_path(self.store.path)
        with self.assertRaisesRegex(FilesystemValidationError, "externally-writable"):
            with checked_directory(self.state, owned_root=self.root):
                self.fail("sticky archive root must not be accepted")

    def test_directory_descriptor_closes_on_body_failure(self):
        descriptor = -1
        with self.assertRaisesRegex(RuntimeError, "fixture"):
            with checked_directory(self.state) as descriptor:
                raise RuntimeError("fixture")
        with self.assertRaises(OSError) as raised:
            os.fstat(descriptor)
        self.assertEqual(raised.exception.errno, errno.EBADF)

    def test_error_translation_does_not_leak_arbitrary_exception_text(self):
        arbitrary = ValueError("private path /fixture/secret command output")
        self.assertEqual(_failure_details(arbitrary), {"reason": "ValueError"})
        process = subprocess.CalledProcessError(1, ["fixture", "secret-argument"],
                                               stderr="secret-output")
        self.assertNotIn("secret", json.dumps(_failure_details(process)))

    def test_actual_registry_and_legacy_cli_private_state_diagnostics(self):
        self.store.path.chmod(0o644)
        root = Path(__file__).resolve().parents[1]
        commands = (
            [str(root / "worker-registry.py"), "--state-dir", str(self.state), "status"],
            [str(root / "worker-legacy-cleanup.py"), "--state-dir", str(self.state),
             "--repos-config", str(self.root / "unused.json"),
             "--output-root", str(self.root / "unused-archives")],
        )
        for command in commands:
            result = subprocess.run(  # nosec B603 # fixed local CLIs, fixture paths
                [sys.executable, "-E", "-s", "-B", *command],
                capture_output=True, text=True, timeout=15, check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "unavailable")
            self.assertEqual(report["reason"], "state-path-must-be-private-and-owned")
            self.assertEqual(report["filesystem_violation"], "not-private")
            self.assertEqual(report["filesystem_path"], str(self.store.path))
        self.assertFalse((self.root / "unused-archives").exists())
