#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for tabby-profile-sync.py compatibility and helpers.

t2250: covers the two root causes behind duplicate Tabby profiles
(``>-`` folded YAML scalars missed by the dedup regex) and worktree
leakage (the string-heuristic failing on names with dots like
``wpallstars.com-chore-aidevops-init``).
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

spec = importlib.util.spec_from_file_location(
    "tabby_profile_sync", SCRIPTS_DIR / "tabby-profile-sync.py"
)
tabby_profile_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tabby_profile_sync)

# Re-import helpers directly so tests exercise the same module the script uses.
from tabby_yaml_helpers import extract_existing_cwds  # noqa: E402


class TestTabbyProfileSync(unittest.TestCase):
    """Test Python 3.9-safe imports and helpers."""

    def test_module_imports_under_current_python(self):
        self.assertTrue(callable(tabby_profile_sync.extract_group_id))

    def test_extract_group_id_returns_projects_group(self):
        config_text = """groups:
  - id: abc-123
    name: Projects
  - id: def-456
    name: Other
profiles:
  - name: repo
"""

        self.assertEqual(tabby_profile_sync.extract_group_id(config_text), "abc-123")


class TestExtractExistingCwds(unittest.TestCase):
    """Regression tests for YAML scalar parsing (t2250 root cause A).

    Before the fix the dedup regex matched only single-line ``cwd: value``
    assignments. Tabby's GUI reformats long paths as folded block scalars
    on every save, causing the dedup check to miss the path and generate a
    duplicate profile on every sync.
    """

    def test_inline_plain_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: /Users/alice/repo
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_inline_single_quoted_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: '/Users/alice/repo'
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_inline_double_quoted_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: "/Users/alice/repo"
"""
        )
        self.assertIn("/Users/alice/repo", cwds)

    def test_folded_block_scalar(self):
        """Tabby's GUI-saved form — the exact shape that caused duplicates."""
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: >-
        /Users/marcusquinn/Git/wordpress/wp-plugin-starter-template-for-ai-coding
    color: '#DA5CD3'
"""
        )
        self.assertIn(
            "/Users/marcusquinn/Git/wordpress/wp-plugin-starter-template-for-ai-coding",
            cwds,
        )
        self.assertNotIn(">-", cwds)

    def test_literal_block_scalar(self):
        cwds = extract_existing_cwds(
            """profiles:
  - name: foo
    options:
      cwd: |-
        /Users/alice/nested/project
"""
        )
        self.assertIn("/Users/alice/nested/project", cwds)
        self.assertNotIn("|-", cwds)

    def test_mixed_forms_in_one_config(self):
        """All three forms in one file are extracted correctly."""
        cwds = extract_existing_cwds(
            """profiles:
  - name: a
    options:
      cwd: /path/a
  - name: b
    options:
      cwd: '/path/b'
  - name: c
    options:
      cwd: >-
        /path/c
  - name: d
    options:
      cwd: |-
        /path/d
"""
        )
        self.assertEqual(
            cwds, {"/path/a", "/path/b", "/path/c", "/path/d"}
        )

    def test_empty_config_returns_empty_set(self):
        self.assertEqual(extract_existing_cwds(""), set())

    def test_config_without_profiles_returns_empty_set(self):
        self.assertEqual(extract_existing_cwds("version: 1\nhotkeys: {}\n"), set())


class TestIsLinkedWorktree(unittest.TestCase):
    """Deterministic worktree detection (t2250 root cause B).

    Replaces the old string-heuristic that tried to guess worktrees from
    basename patterns like ``repo.branch-name``. That heuristic broke for:

    - repo names containing a dot (``wpallstars.com``, ``example.io``)
    - worktrees whose branch prefix is not in the hard-coded list
      (``feature-``, ``bugfix-``, ``hotfix-``, ``refactor-``,
      ``chore-``, ``experiment-``)
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()

    def _git(self, *args, cwd=None):
        subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
        )

    def test_main_worktree_is_not_linked(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        self._git("init", "-q", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(repo)))

    def test_non_git_path_is_not_linked(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(plain)))

    def test_nonexistent_path_is_not_linked(self):
        self.assertFalse(
            tabby_profile_sync.is_linked_worktree(str(self.tmp / "missing"))
        )

    def test_linked_worktree_is_detected(self):
        """The critical case: a linked worktree must return True."""
        repo = self.tmp / "repo"
        repo.mkdir()
        self._git("init", "-q", "-b", "main", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        wt = self.tmp / "repo-feature"
        self._git(
            "worktree", "add", "-q", str(wt), "-b", "feature/x", cwd=repo
        )
        self.assertTrue(tabby_profile_sync.is_linked_worktree(str(wt)))
        # Main remains not-linked.
        self.assertFalse(tabby_profile_sync.is_linked_worktree(str(repo)))

    def test_worktree_with_dot_in_repo_name_is_detected(self):
        """The original bug: worktrees of repos with TLD-style names.

        ``wpallstars.com`` worktree named ``wpallstars.com-chore-aidevops-init``
        was not caught by the old heuristic because splitting on the first
        dot yielded ``com-chore-aidevops-init``, which does not start with
        any of the hard-coded branch prefixes.
        """
        repo = self.tmp / "wpallstars.com"
        repo.mkdir()
        self._git("init", "-q", "-b", "main", cwd=repo)
        self._git("commit", "--allow-empty", "-q", "-m", "init", cwd=repo)
        wt = self.tmp / "wpallstars.com-chore-aidevops-init"
        self._git(
            "worktree", "add", "-q",
            str(wt), "-b", "chore/aidevops-init",
            cwd=repo,
        )
        self.assertTrue(tabby_profile_sync.is_linked_worktree(str(wt)))


class TestGetReposExcludesWorktrees(unittest.TestCase):
    """End-to-end: repos.json entries for worktrees do not reach the sync."""

    def test_worktree_entry_is_filtered(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()

        repo = root / "demo.com"
        repo.mkdir()
        subprocess.run(
            ["git", "init", "-q", "-b", "main"], cwd=repo, check=True
        )
        subprocess.run(
            ["git", "commit", "--allow-empty", "-q", "-m", "init"],
            cwd=repo, check=True,
        )
        wt = root / "demo.com-chore-task"
        subprocess.run(
            ["git", "worktree", "add", "-q", str(wt), "-b", "chore/task"],
            cwd=repo, check=True,
        )

        repos_json = root / "repos.json"
        repos_json.write_text(
            '{{"initialized_repos":[{{"path":"{main}"}},{{"path":"{wt}"}}]}}'.format(
                main=str(repo), wt=str(wt)
            )
        )
        result = tabby_profile_sync.get_repos(str(repos_json))
        paths = [r["path"] for r in result]
        self.assertIn(str(repo), paths)
        self.assertNotIn(str(wt), paths)


if __name__ == "__main__":
    unittest.main()
