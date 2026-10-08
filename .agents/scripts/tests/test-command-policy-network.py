#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Regression checks for trusted, local Git discovery on NixOS workers."""

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from command_policy_network import _run_git_query


class GitQueryTests(unittest.TestCase):
    def test_nix_system_profile_precedes_sandbox_usr_alias(self):
        with patch("command_policy_network.Path.is_file", return_value=True), patch(
            "command_policy_network.os.access", return_value=True
        ), patch("command_policy_network.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "https://github.com/example/repo.git\n")
            self.assertEqual(
                _run_git_query("/worktree", ["remote", "get-url", "--all", "origin"]),
                ["https://github.com/example/repo.git"],
            )
            self.assertEqual(run.call_args.args[0][0], "/run/current-system/sw/bin/git")
            self.assertEqual(run.call_args.args[0][1:], ["-C", "/worktree", "remote", "get-url", "--all", "origin"])

    def test_non_nix_system_keeps_usr_git(self):
        with patch(
            "command_policy_network.Path.is_file",
            autospec=True,
            side_effect=lambda candidate: str(candidate) == "/usr/bin/git",
        ), patch("command_policy_network.os.access", return_value=True), patch(
            "command_policy_network.subprocess.run"
        ) as run:
            run.return_value = subprocess.CompletedProcess([], 0, "origin\n")
            self.assertEqual(_run_git_query("/worktree", ["remote"]), ["origin"])
            self.assertEqual(run.call_args.args[0][0], "/usr/bin/git")

    def test_failed_lookup_remains_fail_closed_without_retry(self):
        with patch("command_policy_network.Path.is_file", return_value=True), patch(
            "command_policy_network.os.access", return_value=True
        ), patch("command_policy_network.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, "")
            self.assertIsNone(_run_git_query("/worktree", ["remote", "get-url", "origin"]))
            run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
