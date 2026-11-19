#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Regression coverage for the procfs runtime evidence harness."""

import importlib.util
from pathlib import Path
import shutil
import subprocess  # nosec B404 - needed to exercise the local shell entry point
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "procfs_fixture", SCRIPTS / "linux-procfs-runtime-fixture.py"
)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class RuntimeEvidenceTest(unittest.TestCase):
    def test_observer_normalizes_fixture_pids_and_preserves_exit_status(self):
        result = subprocess.CompletedProcess(
            [], 2, stdout="99\tignored\n12\tdenied\n13\t12\n", stderr=""
        )
        with patch.object(fixture.subprocess, "run", return_value=result) as run:
            lines = fixture.observe("/scripts", 1000, ["denied"], {12: "sshd", 13: "sshd-priv"})
        self.assertEqual(lines, ["exit=2", "sshd\tdenied", "sshd-priv\tsshd"])
        self.assertEqual(run.call_args.args[0], ["python3", "/scripts/worktree_process_proc.py", "denied"])
        self.assertEqual(run.call_args.kwargs["user"], 1000)
        self.assertEqual(run.call_args.kwargs["extra_groups"], [])

    def test_invalid_uid_fails_before_docker(self):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required to run the harness")
        result = subprocess.run(  # nosec B603 - fixed local script and arguments
            [bash, str(SCRIPTS / "linux-procfs-runtime-check.sh"), "--uid", "0"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("--uid must be a positive integer", result.stderr)

    def test_sudo_session_rejects_missing_repository_before_docker(self):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required to run the harness")
        with tempfile.TemporaryDirectory() as tree:
            result = subprocess.run(  # nosec B603 - fixed local script and arguments
                [bash, str(SCRIPTS / "linux-procfs-runtime-check.sh"), "--sudo-session", "--head", tree],
                capture_output=True, text=True, check=False,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing .agents/scripts/approval-helper.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
