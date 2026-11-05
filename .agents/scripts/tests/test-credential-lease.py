#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Synthetic, offline regressions: no GPG keyring, gopass or saved credential access."""
import importlib.util
import io
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
CLI_SPEC = importlib.util.spec_from_file_location(
    "credential_lease_cli", Path(__file__).resolve().parents[1] / "credential-lease-helper.py")
cli = importlib.util.module_from_spec(CLI_SPEC)
with patch.dict("sys.modules", {"credential_lease": lease}):
    CLI_SPEC.loader.exec_module(cli)
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
        self.values = {"LOCAL_VERIFY_PASSWORD": uuid.uuid4().hex}
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
        for name in ("LD_PRELOAD", "GIT_SSH_COMMAND", "GIT_CONFIG_COUNT", "PERL5OPT", "RUBYOPT"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                lease.validate_values({name: "synthetic"})

    def test_child_is_scoped_and_output_is_not_forwarded(self):
        self.seal()
        with patch.dict(os.environ, {"LOCAL_VERIFY_PASSWORD": uuid.uuid4().hex,
                                     "BETA_TOKEN": uuid.uuid4().hex}):
            # Supervision is mocked, so the Linux-only gate is simulated on any host.
            with patch.object(lease.sys, "platform", "linux"), \
                    patch.object(lease, "open_values", return_value=self.values), \
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
        with patch.object(lease.sys, "platform", "linux"), \
                patch.object(lease, "open_values", return_value=self.values), \
                patch.object(lease.subprocess, "Popen") as spawn, \
                patch.object(lease.os, "waitid", return_value=None), \
                patch.object(lease.time, "monotonic", side_effect=[0, 2]), \
                patch.object(lease, "drain_child", return_value=0) as drain:
            result, code = lease.execute(self.root, self.run_id, ["synthetic-child"], "/", 1)
        drain.assert_called_once_with(spawn.return_value)
        self.assertEqual((result["status"], code), ("child-interrupted", 1))

    def test_repeated_stop_request_never_aborts_group_drain(self):
        previous = lease.signal.getsignal(lease.signal.SIGTERM)

        def stop_during_drain(_child):
            # Deliver SIGTERM through the installed handler mid-drain.
            lease.signal.getsignal(lease.signal.SIGTERM)(lease.signal.SIGTERM, None)
            return 0

        with patch.object(lease.sys, "platform", "linux"), \
                patch.object(lease, "open_values", return_value=self.values), \
                patch.object(lease.subprocess, "Popen"), \
                patch.object(lease.os, "waitid", return_value=object()), \
                patch.object(lease, "drain_child", side_effect=stop_during_drain) as drain:
            result, code = lease.execute(self.root, self.run_id, ["synthetic-child"], "/", 1)
        drain.assert_called_once()
        self.assertEqual((result["status"], code), ("child-interrupted", 1))
        self.assertIs(lease.signal.getsignal(lease.signal.SIGTERM), previous)

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
        with patch.object(lease, "executable", return_value="/synthetic/gpg"), \
                patch.object(lease.subprocess, "run") as command:
            command.return_value.returncode = 0
            command.return_value.stdout = b"synthetic ciphertext"
            self.assertEqual(REAL_CRYPT(b"synthetic input", self.recipient), b"synthetic ciphertext")
        arguments = command.call_args.args[0]
        self.assertEqual(arguments[0], "/synthetic/gpg")
        self.assertEqual(arguments[arguments.index("--pinentry-mode") + 1], "error")
        self.assertIn("--no-auto-key-retrieve", arguments)
        self.assertEqual(command.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_missing_executable_is_refused(self):
        with patch.object(lease.shutil, "which", return_value=None):
            with self.assertRaises(ValueError):
                lease.executable("git")

    def test_each_environment_value_precondition_is_enforced(self):
        invalid = [{}, [], {"valid": "synthetic"}, {"VALUE": 1}, {"VALUE": ""},
                   {"VALUE": "\0"}, {"PATH": "synthetic"}, {"PYTHONPATH": "synthetic"},
                   {"VALUE": "x" * lease.LIMIT}]
        for values in invalid:
            with self.subTest(kind=type(values).__name__):
                with self.assertRaises(ValueError):
                    lease.validate_values(values)


class CliTests(unittest.TestCase):
    def invoke(self, arguments, data=b"{}"):
        with patch.object(cli.sys, "argv", ["credential-lease-helper", *arguments]), \
                patch.object(cli.sys, "stdin", io.TextIOWrapper(io.BytesIO(data))), \
                patch.object(cli.sys, "stdout", io.StringIO()) as output:
            code = cli.main()
        return code, json.loads(output.getvalue())

    def test_capabilities_are_read_only(self):
        with patch.object(lease, "seal") as seal, patch.object(lease, "remove") as remove, \
                patch.object(lease, "execute") as execute:
            self.assertEqual(self.invoke(["capabilities"]), (0, lease.CAPABILITIES))
        for backend in (seal, remove, execute):
            backend.assert_not_called()

    def test_modes_preserve_backend_arguments_and_result(self):
        identity = ["--directory", "/synthetic/run", "--run-id", str(uuid.uuid4())]
        cases = [("seal", [*identity, "--recipient", "A" * 40],
                  ("/synthetic/run", identity[-1], "A" * 40, {})),
                 ("remove", identity, ("/synthetic/run", identity[-1])),
                 ("exec", [*identity, "--cwd", "/", "--budget-seconds", "3", "--", "synthetic-child"],
                  ("/synthetic/run", identity[-1], ["synthetic-child"], "/", 3))]
        result = {"status": "synthetic-backend-result"}
        for mode, options, expected in cases:
            backend_name = "execute" if mode == "exec" else mode
            returned = (result, 7) if mode == "exec" else result
            with self.subTest(mode=mode), patch.object(lease, backend_name, return_value=returned) as backend:
                expected_code = 7 if mode == "exec" else 0
                self.assertEqual(self.invoke([mode, *options]), (expected_code, result))
                backend.assert_called_once_with(*expected)

    def test_invalid_options_are_refused_before_any_backend(self):
        identity = ["--directory", "/synthetic/run", "--run-id", str(uuid.uuid4())]
        cases = [[], ["unknown"], ["capabilities", "--cwd", "/"],
                 ["capabilities", "--", "synthetic-child"], ["seal", *identity],
                 ["seal", *identity, "--recipient", "A" * 40, "--cwd", "/"],
                 ["remove", "--directory", "/synthetic/run"],
                 ["remove", *identity, "--recipient", "A" * 40],
                 ["remove", *identity, "--cwd", "/"],
                 ["remove", *identity, "--", "synthetic-child"], ["exec", *identity],
                 ["exec", *identity, "--cwd", "/", "--recipient", "A" * 40]]
        with patch.object(lease, "seal") as seal, patch.object(lease, "remove") as remove, \
                patch.object(lease, "execute") as execute:
            for arguments in cases:
                with self.subTest(mode=arguments[:1]):
                    self.assertEqual(self.invoke(arguments),
                                     (1, {"status": "lease-refused", "version": lease.VERSION}))
        for backend in (seal, remove, execute):
            backend.assert_not_called()

    def test_oversized_stdin_is_refused_without_sealing(self):
        arguments = ["seal", "--directory", "/synthetic/run", "--run-id", str(uuid.uuid4()),
                     "--recipient", "A" * 40]
        with patch.object(lease, "seal") as seal:
            self.assertEqual(self.invoke(arguments, b"x" * (lease.LIMIT + 1)),
                             (1, {"status": "lease-refused", "version": lease.VERSION}))
        seal.assert_not_called()

    def test_backend_diagnostics_are_never_forwarded(self):
        arguments = ["remove", "--directory", "/synthetic/run", "--run-id", str(uuid.uuid4())]
        with patch.object(lease, "remove", side_effect=ValueError(uuid.uuid4().hex)):
            self.assertEqual(self.invoke(arguments),
                             (1, {"status": "lease-refused", "version": lease.VERSION}))


if __name__ == "__main__":
    unittest.main()
