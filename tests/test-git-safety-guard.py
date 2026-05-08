#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for git_safety_guard.py branch-switch protection."""

import importlib.util
import unittest
from pathlib import Path
from unittest import mock

HOOK_PATH = Path(__file__).parent.parent / ".agents" / "hooks" / "git_safety_guard.py"

spec = importlib.util.spec_from_file_location("git_safety_guard", HOOK_PATH)
git_safety_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(git_safety_guard)


class TestCanonicalBranchSwitchDash(unittest.TestCase):
    """Protect canonical checkouts from ``git switch -`` bypasses."""

    @mock.patch.object(git_safety_guard, "_branch_target_is_current_turn_authorized")
    @mock.patch.object(git_safety_guard, "_get_default_branch", return_value="main")
    @mock.patch.object(git_safety_guard, "_resolve_previous_branch", return_value="feature/work")
    @mock.patch.object(git_safety_guard, "_is_linked_worktree", return_value=False)
    @mock.patch.object(git_safety_guard, "_get_repo_root", return_value="/repo")
    @mock.patch.object(git_safety_guard.os, "getcwd", return_value="/repo")
    def test_git_switch_dash_denies_previous_feature_branch(
        self,
        _getcwd,
        _get_repo_root,
        _is_linked_worktree,
        _resolve_previous_branch,
        _get_default_branch,
        branch_authorized,
    ):
        deny = git_safety_guard._check_canonical_branch_switch_command(
            "git switch -", "restore the canonical repo"
        )

        self.assertIsNotNone(deny)
        reason = deny["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("feature/work", reason)
        branch_authorized.assert_not_called()

    @mock.patch.object(git_safety_guard, "_branch_target_is_current_turn_authorized")
    @mock.patch.object(git_safety_guard, "_get_default_branch", return_value="main")
    @mock.patch.object(git_safety_guard, "_resolve_previous_branch", return_value="main")
    @mock.patch.object(git_safety_guard, "_is_linked_worktree", return_value=False)
    @mock.patch.object(git_safety_guard, "_get_repo_root", return_value="/repo")
    @mock.patch.object(git_safety_guard.os, "getcwd", return_value="/repo")
    def test_git_switch_dash_resolves_default_branch_before_authorization(
        self,
        _getcwd,
        _get_repo_root,
        _is_linked_worktree,
        _resolve_previous_branch,
        _get_default_branch,
        branch_authorized,
    ):
        branch_authorized.return_value = True

        deny = git_safety_guard._check_canonical_branch_switch_command(
            "git switch -", "restore the canonical repo to main"
        )

        self.assertIsNone(deny)
        branch_authorized.assert_called_once_with(
            "main", "restore the canonical repo to main"
        )


if __name__ == "__main__":
    unittest.main()
