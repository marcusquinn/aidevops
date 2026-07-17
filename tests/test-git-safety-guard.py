#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for the shared canonical direct-write policy."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parent.parent
HOOK_PATH = ROOT / ".agents" / "hooks" / "git_safety_guard.py"
POLICY_PATH = ROOT / ".agents" / "scripts" / "canonical-write-policy-helper.py"
REAL_GIT = "/usr/bin/git"

spec = importlib.util.spec_from_file_location("git_safety_guard", HOOK_PATH)
git_safety_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(git_safety_guard)


class CanonicalWritePolicyTests(unittest.TestCase):
    """Exercise canonical and linked contexts through the Claude adapter."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"
        self.linked = self.root / "linked"
        self.repo.mkdir()
        self._git(self.repo, "init", "-q", "-b", "develop")
        self._git(self.repo, "config", "user.name", "Test")
        self._git(self.repo, "config", "user.email", "test@example.invalid")
        self._git(self.repo, "config", "commit.gpgsign", "false")
        (self.repo / "README.md").write_text("seed\n", encoding="utf-8")
        self._git(self.repo, "add", "README.md")
        self._git(self.repo, "commit", "-q", "-m", "seed")
        self._git(
            self.repo,
            "worktree",
            "add",
            "-q",
            "-b",
            "feature/test",
            str(self.linked),
        )

    @staticmethod
    def _git(cwd: Path, *args: str) -> str:
        return subprocess.run(
            [REAL_GIT, *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def _check(self, cwd: Path, target: Path | str = ""):
        with mock.patch.object(git_safety_guard.os, "getcwd", return_value=str(cwd)):
            return git_safety_guard._check_canonical_write(str(target))

    def test_planning_files_are_denied_in_canonical_develop_checkout(self):
        for relative_path in ("README.md", "TODO.md", "todo/task.md"):
            with self.subTest(relative_path=relative_path):
                denial = self._check(self.repo, self.repo / relative_path)
                self.assertIsNotNone(denial)
                reason = denial["hookSpecificOutput"]["permissionDecisionReason"]
                self.assertIn("read-only session mirrors", reason)
                self.assertIn("create_or_use_linked_worktree", reason)

    def test_linked_worktree_write_is_allowed(self):
        self.assertIsNone(self._check(self.linked, self.linked / "new-file.md"))

    def test_linked_context_cannot_target_canonical_checkout(self):
        denial = self._check(self.linked, self.repo / "README.md")
        self.assertIsNotNone(denial)

    def test_missing_policy_helper_fails_closed(self):
        with mock.patch.object(
            git_safety_guard, "_canonical_write_policy_helper", return_value=""
        ):
            denial = self._check(self.linked, self.linked / "README.md")
        self.assertIn(
            "policy is unavailable",
            denial["hookSpecificOutput"]["permissionDecisionReason"],
        )

    def test_namespaced_direct_file_tools_are_classified(self):
        for tool_name in (
            "Edit",
            "write",
            "functions.apply_patch",
            "namespace/Edit",
            "tools::apply-patch",
        ):
            with self.subTest(tool_name=tool_name):
                self.assertTrue(git_safety_guard._is_direct_file_tool(tool_name))
        self.assertFalse(git_safety_guard._is_direct_file_tool("functions.read"))

    def test_runtime_neutral_classifier_reports_structure(self):
        canonical = subprocess.run(
            [
                "python3",
                str(POLICY_PATH),
                "classify",
                "--cwd",
                str(self.repo),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        linked = subprocess.run(
            [
                "python3",
                str(POLICY_PATH),
                "classify",
                "--cwd",
                str(self.linked),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(json.loads(canonical.stdout)["classification"], "canonical")
        self.assertEqual(json.loads(linked.stdout)["classification"], "linked")

    def test_explicit_project_integration_branch_is_resolved(self):
        (self.repo / ".aidevops.json").write_text(
            json.dumps({"pr_base_branch": "develop"}), encoding="utf-8"
        )
        result = subprocess.run(
            [
                "python3",
                str(POLICY_PATH),
                "resolve-branch",
                "--cwd",
                str(self.repo),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["branch"], "develop")
        self.assertEqual(payload["source"], "project-config")


if __name__ == "__main__":
    unittest.main()
