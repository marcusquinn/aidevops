#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Synthetic, offline regressions: no GPG keyring, gopass or saved credential access."""
import importlib.util
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
owned = importlib.import_module("credential_lease_owned")

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
        TEST_BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
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

    def owned_contract(self, names=None, results=None):
        contract = {"version": 1, "configurationNames": names or [],
                    "results": results or [{"exitCode": 0, "value": {"outcome": "matching"}}]}
        data = json.dumps(contract).encode()
        path = self.root / "result-contract.json"
        lease.exclusive_write(path, data)
        return str(path), hashlib.sha256(data).hexdigest()

    def owned_options(self, path="unused", digest="unused", names=None):
        return {"cwd": "/", "budget": 1,
                "names": names if names is not None else ["LOCAL_VERIFY_PASSWORD"],
                "ownerPid": 123, "ownerStarted": "456", "contract": path,
                "contractDigest": digest, "configurationFd": 3}

    def owned_execution(self, output=b'{"outcome":"matching"}', code=0, configuration=None):
        configuration = configuration or {}
        path, digest = self.owned_contract(names=list(configuration))
        self.seal()
        with patch.object(lease, "assert_owned_ancestor") as owner, \
                patch.object(lease, "_read_configuration", return_value=configuration), \
                patch.object(lease, "_owned_child_output", return_value=(output, code)) as child:
            result = lease.execute_owned(self.root, self.run_id, ["synthetic-child"],
                                         self.owned_options(path, digest))
        return result, child.call_args, owner.call_count

    def test_owned_execution_selects_only_requested_values_and_explicit_configuration(self):
        self.values["UNRELATED_TOKEN"] = uuid.uuid4().hex
        configuration = {"DATABASE_URL": "synthetic-owned-database", "NODE_ENV": "development"}
        with patch.dict(os.environ, {"UNRELATED_TOKEN": uuid.uuid4().hex, "NODE_OPTIONS": "hook-canary"}):
            result, call, checks = self.owned_execution(configuration=configuration)
        self.assertEqual(result, ({"status": "owned-child-result", "version": 1,
                                   "result": {"outcome": "matching"}, "exitCode": 0}, 0))
        env = call.args[2]
        self.assertEqual(env["LOCAL_VERIFY_PASSWORD"], self.values["LOCAL_VERIFY_PASSWORD"])
        self.assertEqual(env["DATABASE_URL"], configuration["DATABASE_URL"])
        self.assertNotIn("UNRELATED_TOKEN", env)
        self.assertNotIn("NODE_OPTIONS", env)
        self.assertEqual(checks, 3)

    def test_owned_execution_never_forwards_unknown_or_augmented_output(self):
        samples = [b"raw-sql-parameter-canary", b'{"outcome":"matching","email":"canary"}',
                   b'{"outcome":"matching","outcome":"matching"}',
                   b'{"outcome":"matching"} trailing', b'[]', b'\xff']
        for sample in samples:
            # Each attempt has its own private contract and synthetic capsule.
            with self.subTest(kind=sample[:1]):
                result, _, _ = self.owned_execution(sample)
                self.assertEqual(result, ({"status": "owned-child-unverified", "version": 1}, 1))
                lease.remove(self.root, self.run_id)
                for path in self.root.iterdir():
                    path.unlink()

    def test_owned_execution_rejects_exit_mismatch_and_uncertain_transport(self):
        result, _, _ = self.owned_execution(code=1)
        self.assertEqual(result, ({"status": "owned-child-unverified", "version": 1}, 1))

    def test_owned_execution_owner_refusal_precedes_decryption(self):
        with patch.object(lease, "assert_owned_ancestor", side_effect=ValueError("owner")), \
                patch.object(lease, "open_values") as decrypt:
            with self.assertRaises(ValueError):
                lease.execute_owned(self.root, self.run_id, ["synthetic-child"], self.owned_options())
        decrypt.assert_not_called()

    def test_owned_execution_rejects_duplicate_selection_before_decryption(self):
        with patch.object(lease, "assert_owned_ancestor"), patch.object(lease, "open_values") as decrypt:
            with self.assertRaises(ValueError):
                lease.execute_owned(self.root, self.run_id, ["synthetic-child"],
                                    self.owned_options(names=["VALUE", "VALUE"]))
        decrypt.assert_not_called()

    def test_contract_digest_and_private_file_are_enforced(self):
        path, digest = self.owned_contract()
        self.seal()
        with self.assertRaises(ValueError):
            lease._execution_contract(self.root, self.run_id, path, "0" * 64)
        Path(path).chmod(0o644)
        with self.assertRaises(ValueError):
            lease._execution_contract(self.root, self.run_id, path, digest)

    def test_configuration_cannot_shadow_selected_credentials(self):
        path, digest = self.owned_contract(names=["LOCAL_VERIFY_PASSWORD"])
        self.seal()
        with patch.object(lease, "assert_owned_ancestor"), patch.object(lease, "open_values") as decrypt:
            with self.assertRaises(ValueError):
                lease.execute_owned(self.root, self.run_id, ["synthetic-child"],
                                    self.owned_options(path, digest))
        decrypt.assert_not_called()

    def test_configuration_pipe_is_memory_only_exact_and_loader_safe(self):
        cases = [(b'{"NODE_ENV":"development"}', ["NODE_ENV"], True),
                 (b'{"NODE_ENV":"production"}', ["NODE_ENV"], False),
                 (b'{"NODE_OPTIONS":"hook-canary"}', ["NODE_OPTIONS"], False),
                 (b'{"VALUE":"first","VALUE":"second"}', ["VALUE"], False),
                 (b'{"EXTRA":"canary"}', [], False)]
        for data, names, valid in cases:
            read, write = os.pipe()
            os.write(write, data)
            os.close(write)
            if valid:
                self.assertEqual(lease._read_configuration(read, names), {"NODE_ENV": "development"})
            else:
                with self.assertRaises(ValueError):
                    lease._read_configuration(read, names)

    def test_owned_ancestor_requires_matching_live_kernel_identity_and_group(self):
        identities = {27: {"parent": 30, "group": 42, "started": "100"},
                      30: {"parent": 42, "group": 42, "started": "99"},
                      42: {"parent": 5, "group": 42, "started": "98"}}
        with patch.object(lease.sys, "platform", "linux"), \
                patch.object(lease.os, "getpid", return_value=27), \
                patch.object(lease.os, "getpgrp", return_value=42), \
                patch.object(owned, "_process_identity", side_effect=identities.__getitem__):
            lease.assert_owned_ancestor(42, "98")
            with self.assertRaises(ValueError):
                lease.assert_owned_ancestor(42, "97")
            with self.assertRaises(ValueError):
                lease.assert_owned_ancestor(30, "99")

    @unittest.skipUnless(sys.platform == "linux" and sys.version_info >= (3, 11), "Linux owner protocol")
    def test_owned_child_remains_in_existing_group_and_bounds_output_and_time(self):
        environment = {"PATH": os.environ["PATH"]}
        # Only synthetic interpreter children, never GPG or application commands.
        data, code = lease._owned_child_output(
            [sys.executable, "-c", "import json,os; print(json.dumps({'group':os.getpgrp()}))"],
            "/", environment, 2, [])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(data)["group"], os.getpgrp())
        self.assertEqual(lease._owned_child_output(
            [sys.executable, "-c", "import os; os.write(1,b'x'*70000)"],
            "/", environment, 2, []), (None, None))
        self.assertEqual(lease._owned_child_output(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            "/", environment, 0.05, []), (None, None))

    def test_stop_during_owned_result_transport_never_becomes_success(self):
        path, digest = self.owned_contract()
        self.seal()
        previous = lease.signal.getsignal(lease.signal.SIGTERM)

        def interrupted_output(*_arguments):
            lease.signal.getsignal(lease.signal.SIGTERM)(lease.signal.SIGTERM, None)
            return b'{"outcome":"matching"}', 0

        with patch.object(lease, "assert_owned_ancestor"), \
                patch.object(lease, "_read_configuration", return_value={}), \
                patch.object(lease, "_owned_child_output", side_effect=interrupted_output):
            result = lease.execute_owned(self.root, self.run_id, ["synthetic-child"],
                                         self.owned_options(path, digest))
        self.assertEqual(result, ({"status": "owned-child-unverified", "version": 1}, 1))
        self.assertIs(lease.signal.getsignal(lease.signal.SIGTERM), previous)

    def test_contract_rejects_loader_configuration_before_decryption(self):
        path, digest = self.owned_contract(names=["NODE_OPTIONS"])
        self.seal()
        with patch.object(lease, "assert_owned_ancestor"), patch.object(lease, "open_values") as decrypt:
            with self.assertRaises(ValueError):
                lease.execute_owned(self.root, self.run_id, ["synthetic-child"],
                                    self.owned_options(path, digest))
        decrypt.assert_not_called()

    def test_contract_refuses_hardlinks(self):
        path, digest = self.owned_contract()
        self.seal()
        os.link(path, self.root / "extra-contract-link")
        with self.assertRaises(ValueError):
            lease._execution_contract(self.root, self.run_id, path, digest)


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

    def test_owned_execution_options_are_not_accepted_by_legacy_modes(self):
        with patch.object(lease, "execute_owned") as owned:
            self.assertEqual(self.invoke(["capabilities", "--owner-pid", "123"]),
                             (1, {"status": "lease-refused", "version": lease.VERSION}))
            self.assertEqual(self.invoke(["exec-owned", "--configuration-fd", "0"]),
                             (1, {"status": "lease-refused", "version": lease.VERSION}))
        owned.assert_not_called()

    def test_owned_mode_preserves_scoped_arguments_and_sanitizes_backend_errors(self):
        run_id = str(uuid.uuid4())
        arguments = ["exec-owned", "--directory", "/synthetic/run", "--run-id", run_id,
                     "--cwd", "/", "--budget-seconds", "3", "--select", "FIRST_VALUE",
                     "--select", "SECOND_VALUE", "--owner-pid", "123", "--owner-started", "456",
                     "--contract", "/synthetic/run/result.json", "--contract-sha256", "a" * 64,
                     "--configuration-fd", "3", "--", "synthetic-child"]
        result = {"status": "owned-child-unverified", "version": 1}
        with patch.object(lease, "execute_owned", return_value=(result, 1)) as owned:
            self.assertEqual(self.invoke(arguments), (1, result))
        owned.assert_called_once_with("/synthetic/run", run_id, ["synthetic-child"], {
            "cwd": "/", "budget": 3, "names": ["FIRST_VALUE", "SECOND_VALUE"],
            "ownerPid": 123, "ownerStarted": "456", "contract": "/synthetic/run/result.json",
            "contractDigest": "a" * 64, "configurationFd": 3})
        with patch.object(lease, "execute_owned", side_effect=ValueError("raw-sql-canary")):
            self.assertEqual(self.invoke(arguments), (1, {"status": "lease-refused", "version": 1}))


if __name__ == "__main__":
    unittest.main()
