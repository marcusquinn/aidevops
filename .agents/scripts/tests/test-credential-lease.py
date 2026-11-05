#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Synthetic, offline regressions: no GPG keyring, gopass or saved credential access."""
import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location(
    "credential_lease", Path(__file__).resolve().parents[1] / "credential_lease.py")
lease = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lease)
REAL_CRYPT = lease.crypt
TEST_BASE = Path(os.environ.get("AIDEVOPS_TEMP_DIR",
                               str(Path.home() / ".aidevops/.agent-workspace/tmp")))


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lease-unit-", dir=TEST_BASE)
        self.base = Path(self.temporary.name)
        self.root = self.base / "run"
        self.root.mkdir(mode=0o700)
        self.run_id = str(uuid.uuid4())
        self.environment = patch.dict(os.environ, {"AIDEVOPS_TEMP_DIR": str(self.base)})
        self.environment.start()
        self.values = {"LOCAL_VERIFY_PASSWORD": "synthetic-canary-not-a-credential"}
        self.recipient = "A" * 40
        self.envelope = None

        def crypto(data, recipient=None):
            if recipient:
                self.envelope = data
                return b"opaque synthetic ciphertext"
            return self.envelope

        self.crypto = patch.object(lease, "crypt", side_effect=crypto)
        self.crypto.start()

    def tearDown(self):
        self.crypto.stop()
        self.environment.stop()
        self.temporary.cleanup()

    def seal(self):
        return lease.seal(self.root, self.run_id, self.recipient, self.values)

    def test_roundtrip_and_idempotent_removal_keep_values_off_disk(self):
        self.assertEqual(self.seal()["status"], "sealed")
        self.assertEqual(lease.open_values(self.root, self.run_id), self.values)
        for path in self.root.iterdir():
            self.assertNotIn(self.values["LOCAL_VERIFY_PASSWORD"].encode(), path.read_bytes())
        self.assertEqual(lease.remove(self.root, self.run_id)["status"], "removed")
        self.assertEqual(lease.remove(self.root, self.run_id)["status"], "removed")
        self.assertTrue((self.root / lease.RECEIPT).exists())

    def test_existing_entry_is_never_replaced(self):
        self.seal()
        original = (self.root / lease.FILES[1]).read_bytes()
        with self.assertRaises(ValueError):
            self.seal()
        self.assertEqual((self.root / lease.FILES[1]).read_bytes(), original)

    def test_wrong_run_and_replaced_ciphertext_refuse_read_and_removal(self):
        self.seal()
        with self.assertRaises(ValueError):
            lease.remove(self.root, str(uuid.uuid4()))
        path = self.root / lease.FILES[1]
        path.unlink()
        path.write_bytes(b"another owner's encrypted value")
        path.chmod(0o600)
        for operation in (lease.open_values, lease.remove):
            with self.assertRaises(ValueError):
                operation(self.root, self.run_id)
        self.assertEqual(path.read_bytes(), b"another owner's encrypted value")

    def test_changed_content_with_same_inode_is_preserved(self):
        self.seal()
        path = self.root / lease.FILES[1]
        path.write_bytes(b"changed ciphertext")
        with self.assertRaises(ValueError):
            lease.remove(self.root, self.run_id)
        self.assertTrue(path.exists())

    def test_interrupted_publication_is_recoverable(self):
        with patch.object(lease.os, "link", side_effect=OSError("synthetic interruption")):
            with self.assertRaises(OSError):
                self.seal()
        self.assertTrue((self.root / lease.FILES[0]).exists())
        self.assertEqual(lease.remove(self.root, self.run_id)["status"], "removed")

    def test_unreceipted_ciphertext_refuses_cleanup(self):
        lease.exclusive_write(self.root / lease.FILES[0], b"unknown ciphertext")
        with self.assertRaises(FileNotFoundError):
            lease.remove(self.root, self.run_id)
        self.assertTrue((self.root / lease.FILES[0]).exists())

    def test_symlink_and_public_directory_refused(self):
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            self.seal()
        self.root.chmod(0o700)
        (self.root / lease.FILES[1]).symlink_to(self.base / "missing")
        with self.assertRaises(ValueError):
            self.seal()

    def test_mismatched_envelope_and_environment_injection_refused(self):
        self.seal()
        payload = json.loads(self.envelope)
        payload["runId"] = str(uuid.uuid4())
        self.envelope = json.dumps(payload).encode()
        with self.assertRaises(ValueError):
            lease.open_values(self.root, self.run_id)
        with self.assertRaises(ValueError):
            lease.validate_values({"LD_PRELOAD": "synthetic"})

    def test_child_is_scoped_and_output_is_not_forwarded(self):
        self.seal()
        with patch.dict(os.environ, {"LOCAL_VERIFY_PASSWORD": "shadow", "BETA_TOKEN": "foreign"}):
            with patch.object(lease, "open_values", return_value=self.values), \
                    patch.object(lease.subprocess, "Popen") as spawn, \
                    patch.object(lease.os, "waitid", return_value=object()), \
                    patch.object(lease, "drain_child", return_value=0):
                spawn.return_value.wait.return_value = 0
                result, code = lease.execute(self.root, self.run_id, ["synthetic-child"], "/", 1)
        self.assertEqual((result["status"], code), ("child-passed", 0))
        options = spawn.call_args.kwargs
        self.assertEqual(options["env"]["LOCAL_VERIFY_PASSWORD"], self.values["LOCAL_VERIFY_PASSWORD"])
        self.assertNotIn("BETA_TOKEN", options["env"])
        self.assertEqual(options["stdout"], subprocess.DEVNULL)
        self.assertEqual(options["stderr"], subprocess.DEVNULL)
        self.assertEqual(options["process_group"], 0)

    def test_child_timeout_terminates_before_failure(self):
        self.seal()
        with patch.object(lease, "open_values", return_value=self.values), \
                patch.object(lease.subprocess, "Popen") as spawn, \
                patch.object(lease.os, "waitid", return_value=None), \
                patch.object(lease.time, "monotonic", side_effect=[0, 2]), \
                patch.object(lease, "drain_child", return_value=0) as drain:
            result, code = lease.execute(self.root, self.run_id, ["synthetic-child"], "/", 1)
        drain.assert_called_once_with(spawn.return_value)
        self.assertEqual((result["status"], code), ("child-interrupted", 1))


    def test_process_group_is_signalled_before_leader_is_reaped(self):
        from unittest.mock import Mock
        child = Mock(pid=987654321)
        events = []
        child.wait.side_effect = lambda **_kwargs: events.append("wait") or 0
        with patch.object(lease.os, "killpg", side_effect=lambda *_args: events.append("signal")), \
                patch.object(lease, "live_group_members", return_value=[]):
            self.assertEqual(lease.drain_child(child), 0)
        self.assertEqual(events, ["signal", "wait"])

    def test_uncertain_descendant_cleanup_never_passes(self):
        from unittest.mock import Mock
        child = Mock(pid=987654321)
        with patch.object(lease.os, "killpg") as signal_group, \
                patch.object(lease, "live_group_members", return_value=[child.pid]), \
                patch.object(lease.time, "monotonic", side_effect=itertools.count(0, 20)):
            with self.assertRaises(ValueError):
                lease.drain_child(child)
        self.assertEqual(signal_group.call_count, 2)

    def test_already_empty_owned_group_is_reaped_without_signalling_others(self):
        from unittest.mock import Mock
        child = Mock(pid=987654321)
        child.wait.return_value = 0
        with patch.object(lease.os, "killpg", side_effect=ProcessLookupError) as signal_group, \
                patch.object(lease, "live_group_members", return_value=[]):
            self.assertEqual(lease.drain_child(child), 0)
        signal_group.assert_called_once_with(child.pid, lease.signal.SIGTERM)
        child.wait.assert_called_once_with(timeout=5)

    def test_crypto_refuses_interactive_unlock_and_never_prints_backend_errors(self):
        with patch.object(lease.subprocess, "run") as command:
            command.return_value.returncode = 0
            command.return_value.stdout = b"synthetic ciphertext"
            self.assertEqual(REAL_CRYPT(b"synthetic input", self.recipient), b"synthetic ciphertext")
        arguments = command.call_args.args[0]
        self.assertEqual(arguments[arguments.index("--pinentry-mode") + 1], "error")
        self.assertIn("--no-auto-key-retrieve", arguments)
        self.assertEqual(command.call_args.kwargs["stderr"], subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
