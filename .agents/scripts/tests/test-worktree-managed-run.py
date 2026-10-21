#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Managed runner capability, startup and output-transport contracts."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_lifetime_owner as owner

SPEC = importlib.util.spec_from_file_location("managed_run", SCRIPTS / "worktree-managed-run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerControlTests(unittest.TestCase):
    def test_macos_probe_never_invokes_systemd(self):
        with patch.object(sys, "platform", "darwin"), patch.object(runner.subprocess, "check_output") as call:
            self.assertFalse(runner.backend_available())
            call.assert_not_called()

    def test_unavailable_user_manager_selects_legacy_before_creation(self):
        with patch.object(sys, "platform", "linux"), patch.object(Path, "is_file", return_value=True), \
                patch.object(runner.shutil, "which", return_value="/fixture/tool"), \
                patch.object(runner.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "systemctl")):
            self.assertFalse(runner.backend_available())

    def test_nonterminal_service_never_inherits_tool_output_pipes(self):
        with patch.object(sys.stdin, "isatty", return_value=False), runner.isolated_service_io() as (stdio, _, mode):
            self.assertEqual(mode, "--pipe")
            self.assertEqual(stdio["stdin"], subprocess.DEVNULL)
            for key in ("stdout", "stderr"):
                self.assertTrue(stat.S_ISREG(os.fstat(stdio[key].fileno()).st_mode))

    def test_backend_requires_supported_version_on_session_bus(self):
        for version, help_text, expected in (("249", "--expand-environment", False),
                                             ("250", "--expand-environment", True),
                                             ("259.1", "--expand-environment", True),
                                             ("250", "older CLI", False), (None, "", False)):
            with self.subTest(version=version), patch.object(sys, "platform", "linux"), \
                    patch.object(Path, "is_file", return_value=True), \
                    patch.object(runner.shutil, "which", return_value="/fixture/tool"), \
                    patch.object(runner.subprocess, "check_output", side_effect=[json.dumps({"data": version}), help_text]) as call:
                self.assertEqual(runner.backend_available(), expected)
                self.assertEqual(call.call_args_list[0].args[0][0], "busctl")

    def test_loaded_unit_without_invocation_is_pending_not_replaced(self):
        ready = {"InvocationID": "first", "MainPID": "0", "Job": "",
                 "ActiveState": "active", "SubState": "exited"}
        client = Mock()
        client.poll.return_value = None
        with patch.object(owner, "unit_snapshot", side_effect=[{"InvocationID": ""}, ready]), \
                patch.object(runner.time, "sleep"):
            self.assertEqual(runner.wait_for_unit("fixture", client, time.monotonic() + 1), ready)

    def test_deadline_refuses_without_waiting_for_client_eof(self):
        with self.assertRaises(ValueError):
            runner.wait_for_unit("fixture", Mock(), time.monotonic() - 1)

    def test_native_service_preserves_caller_umask(self):
        if not runner.backend_available():
            self.skipTest("rootless user-systemd unavailable")
        for mask in (0o022, 0o077, 0o002):
            with self.subTest(mask=oct(mask)):
                result = subprocess.run(
                    [sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                     "--timeout-seconds", "20", "--", sys.executable, "-c",
                     "import os; print(oct(os.umask(0o077)))"],
                    umask=mask, capture_output=True, text=True, timeout=30, check=True)
                self.assertEqual(result.stdout.strip(), oct(mask))


if __name__ == "__main__":
    unittest.main()
