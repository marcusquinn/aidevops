"""Shared native contract tests; run unchanged on Linux and macOS."""

import contextlib
import io
import json
import os
import subprocess  # nosec B404 # bounded, owned native probes only
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from worker_lifecycle.__main__ import main
from worker_lifecycle.linux import LinuxProcesses
from worker_lifecycle.process import ObservationUnavailable, ProcessIdentity
from worker_lifecycle.runtime import adapter_for, require_ready


class NativeContract(unittest.TestCase):
    def setUp(self):
        self.adapter = adapter_for(str(uuid4()))
        # Failure here is a failed environment contract, never a silent skip.
        require_ready(self.adapter)

    def test_self_identity_round_trip(self):
        identity = self.adapter.capture(os.getpid())
        restored = ProcessIdentity.from_dict(json.loads(json.dumps(identity.to_dict())))
        self.assertEqual(identity, restored)
        self.assertEqual(self.adapter.observe(restored).status, "alive")

    def test_foreign_installation_is_unknown(self):
        identity = self.adapter.capture(os.getpid())
        self.assertEqual(self.adapter.observe(replace(identity, installation_id=str(uuid4()))).status, "unknown")

    def test_unknown_schema_is_not_death(self):
        identity = self.adapter.capture(os.getpid())
        self.assertEqual(self.adapter.observe(replace(identity, schema=99)).status, "unknown")

    def test_foreign_scope_is_unknown(self):
        identity = self.adapter.capture(os.getpid())
        self.assertEqual(self.adapter.observe(replace(identity, scope="unrecognized")).status, "unknown")

    def test_invalid_pid(self):
        for pid in (0, -1, True, 2**32):
            with self.subTest(pid=pid), self.assertRaises(ValueError):
                self.adapter.capture(pid)

    def test_live_child_fresh_observer_then_natural_exit(self):
        child_code = "import select,sys; r,_,_=select.select([sys.stdin],[],[],10); sys.stdin.read(1) if r else None"
        with subprocess.Popen([sys.executable, "-I", "-c", child_code], stdin=subprocess.PIPE) as child:  # nosec B603 # fixed probe code
            try:
                identity = self.adapter.capture(child.pid)
                self.assertEqual(self.adapter.observe(identity).status, "alive")
                fresh = subprocess.run(  # nosec B603 # fixed observer CLI; identity is stdin data
                    [sys.executable, "-B", "-m", "worker_lifecycle", "--installation-id",
                     identity.installation_id, "observe"],
                    input=json.dumps(identity.to_dict()), text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(fresh.returncode, 0, fresh.stderr)
                self.assertEqual(json.loads(fresh.stdout)["status"], "alive")
            finally:
                child.stdin.close()
                child.wait(timeout=12)
            self.assertEqual(self.adapter.observe(identity).status, "ended")


class LinuxVisibilityContract(unittest.TestCase):
    def test_hidden_pid_requires_independent_absence_confirmation(self):
        adapter = LinuxProcesses(str(uuid4()))
        identity = ProcessIdentity(1, adapter.installation_id, "linux", str(uuid4()),
                                   "pidns:test", 12345, "123", 1000)
        for error, expected in ((None, "unknown"), (PermissionError(), "unknown"),
                                (ProcessLookupError(), "ended")):
            with self.subTest(error=error), \
                    patch.object(adapter, "_sample", side_effect=FileNotFoundError()), \
                    patch.object(Path, "stat", side_effect=FileNotFoundError()), \
                    patch("worker_lifecycle.linux.os.kill", side_effect=error) as exists:
                self.assertEqual(adapter._observe_current(identity).status, expected)
                exists.assert_called_once_with(identity.pid, 0)


class ReadinessContract(unittest.TestCase):
    def test_decoder_recursion_error_returns_structured_unknown(self):
        with patch("worker_lifecycle.__main__.require_ready"), \
                patch("sys.argv", ["worker_lifecycle", "--installation-id", str(uuid4()), "observe"]), \
                patch("sys.stdin", io.StringIO("[]")), \
                patch("worker_lifecycle.__main__.json.loads", side_effect=RecursionError), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(), 2)
        self.assertEqual(json.loads(output.getvalue())["status"], "unknown")

    def test_boot_denial_stops_before_target_or_stdin(self):
        with patch("worker_lifecycle.__main__.adapter_for") as factory, \
                patch("sys.argv", ["worker_lifecycle", "--installation-id", str(uuid4()), "observe"]), \
                patch("sys.stdin") as stdin, contextlib.redirect_stdout(io.StringIO()) as output:
            factory.return_value.capture.side_effect = ObservationUnavailable("boot-identity-permission-denied")
            self.assertEqual(main(), 2)
            factory.return_value.capture.assert_called_once_with(os.getpid())
            factory.return_value.observe.assert_not_called()
            stdin.read.assert_not_called()
            self.assertEqual(json.loads(output.getvalue())["reason"], "boot-identity-permission-denied")

    def test_unsupported_platform(self):
        with patch("sys.platform", "unsupported"), self.assertRaises(ObservationUnavailable):
            adapter_for(str(uuid4()))


if __name__ == "__main__":
    unittest.main()
