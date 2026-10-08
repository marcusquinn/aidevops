#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Regression checks for trusted, local Git discovery across Linux layouts."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from command_policy_network import _resolve_git_remote, _run_git_query


class GitQueryTests(unittest.TestCase):
    def test_nix_system_profile_precedes_sandbox_usr_alias(self):
        with patch("command_policy_git_query.Path.is_file", return_value=True), patch(
            "command_policy_git_query.os.access", return_value=True
        ), patch("command_policy_git_query.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "https://github.com/example/repo.git\n")
            self.assertEqual(
                _run_git_query("/worktree", ["remote", "get-url", "--all", "origin"]),
                ["https://github.com/example/repo.git"],
            )
            self.assertEqual(run.call_args.args[0][0], "/run/current-system/sw/bin/git")
            self.assertEqual(run.call_args.args[0][1:], ["-C", "/worktree", "remote", "get-url", "--all", "origin"])

    def test_non_nix_system_keeps_usr_git(self):
        with patch(
            "command_policy_git_query.Path.is_file",
            autospec=True,
            side_effect=lambda candidate: str(candidate) == "/usr/bin/git",
        ), patch("command_policy_git_query.os.access", return_value=True), patch(
            "command_policy_git_query.subprocess.run"
        ) as run:
            run.return_value = subprocess.CompletedProcess([], 0, "origin\n")
            self.assertEqual(_run_git_query("/worktree", ["remote"]), ["origin"])
            self.assertEqual(run.call_args.args[0][0], "/usr/bin/git")

    def test_bin_git_supports_alternative_system_layout(self):
        with patch(
            "command_policy_git_query.Path.is_file",
            autospec=True,
            side_effect=lambda candidate: str(candidate) == "/bin/git",
        ), patch("command_policy_git_query.os.access", return_value=True), patch(
            "command_policy_git_query.subprocess.run"
        ) as run:
            run.return_value = subprocess.CompletedProcess([], 0, "origin\n")
            self.assertEqual(_run_git_query("/worktree", ["remote"]), ["origin"])
            self.assertEqual(run.call_args.args[0][0], "/bin/git")

    def test_path_fallback_when_no_system_candidate_exists(self):
        with patch("command_policy_git_query.Path.is_file", return_value=False), patch(
            "command_policy_git_query.subprocess.run"
        ) as run:
            run.return_value = subprocess.CompletedProcess([], 0, "origin\n")
            self.assertEqual(_run_git_query("/worktree", ["remote"]), ["origin"])
            self.assertEqual(run.call_args.args[0][0], "git")

    def test_non_executable_system_candidate_is_skipped(self):
        with patch("command_policy_git_query.Path.is_file", return_value=True), patch(
            "command_policy_git_query.os.access",
            side_effect=lambda candidate, mode: candidate == "/usr/bin/git" and mode == os.X_OK,
        ), patch("command_policy_git_query.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "origin\n")
            self.assertEqual(_run_git_query("/worktree", ["remote"]), ["origin"])
            self.assertEqual(run.call_args.args[0][0], "/usr/bin/git")

    def test_failed_lookup_remains_fail_closed_without_transport_fallback(self):
        with patch("command_policy_git_query.Path.is_file", return_value=True), patch(
            "command_policy_git_query.os.access", return_value=True
        ), patch("command_policy_git_query.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, "")
            self.assertIsNone(_run_git_query("/worktree", ["remote", "get-url", "origin"]))
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args_list[0], run.call_args_list[1])

    def test_missing_git_and_timeout_remain_fail_closed(self):
        for error in (FileNotFoundError("git unavailable"), subprocess.TimeoutExpired("git", 5)):
            with self.subTest(error=type(error).__name__), patch(
                "command_policy_git_query.Path.is_file", return_value=False
            ), patch("command_policy_git_query.subprocess.run", side_effect=error) as run:
                self.assertIsNone(_run_git_query("/worktree", ["remote", "get-url", "origin"]))
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args_list[0], run.call_args_list[1])

    def test_real_git_resolves_fetch_and_push_urls_without_network(self):
        git_binary = shutil.which("git")
        self.assertIsNotNone(git_binary, "Real Git is required; do not skip the integration assertion")
        self.assertTrue(os.path.isabs(git_binary))
        with tempfile.TemporaryDirectory(prefix="git-discovery-", dir=os.environ.get("AIDEVOPS_TEMP_DIR")) as root:
            subprocess.run(  # nosec B603 -- absolute executable, fixed argv and test-owned fixture; no shell execution.
                [git_binary, "init", "--quiet", root], check=True, capture_output=True, timeout=5,
            )
            fetch_url = "https://github.com/example/repo.git"
            push_url = "https://github.com/example/push.git"
            subprocess.run(  # nosec B603 -- absolute executable, fixed argv and test-owned fixture; no shell execution.
                [git_binary, "-C", root, "remote", "add", "origin", fetch_url],
                check=True, capture_output=True, timeout=5,
            )
            subprocess.run(  # nosec B603 -- absolute executable, fixed argv and test-owned fixture; no shell execution.
                [git_binary, "-C", root, "remote", "set-url", "--push", "origin", push_url],
                check=True, capture_output=True, timeout=5,
            )
            self.assertEqual(_resolve_git_remote(root, "origin"), [fetch_url])
            self.assertEqual(_resolve_git_remote(root, "origin", include_push=True), [fetch_url, push_url])
            self.assertEqual(_resolve_git_remote(root, "missing"), [])


if __name__ == "__main__":
    unittest.main()
