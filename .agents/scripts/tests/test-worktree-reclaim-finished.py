#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fixture-only reclaim evidence tests: every incomplete signal must refuse removal."""

import importlib.util
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed offline Git fixtures only.
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
GIT = shutil.which("git")
if not GIT:
    raise RuntimeError("Git is required for fixture verification")
SPEC = importlib.util.spec_from_file_location("reclaim", SCRIPTS / "worktree-reclaim-finished.py")
reclaim = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reclaim)

SLUG = "fixture/repo"


def git(path, *arguments):
    subprocess.run([GIT, "-C", str(path), *arguments], check=True,  # nosec B603
                   capture_output=True, text=True)


class ReferenceTests(unittest.TestCase):
    def test_extracts_issue_and_pull_request_numbers(self):
        self.assertEqual(reclaim.references("repo-feature-auto-20261112-gh22419"),
                         [("gh", 22419)])
        self.assertEqual(reclaim.references("repo-pr36801-ci-repair-abc"), [("pr", 36801)])
        self.assertEqual(reclaim.references("repo-pr22476-review-gh22443-abc"),
                         [("pr", 22476), ("gh", 22443)])

    def test_reports_no_reference_when_name_encodes_none(self):
        self.assertEqual(reclaim.references("repo-manual-investigation"), [])


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="reclaim-fixture-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.origin = self.root / "origin.git"
        subprocess.run([GIT, "init", "--bare", "-q", str(self.origin)],  # nosec B603
                       check=True, capture_output=True)
        self.canonical = self.root / "repo"
        subprocess.run([GIT, "clone", "-q", str(self.origin), str(self.canonical)],  # nosec B603
                       check=True, capture_output=True)
        git(self.canonical, "config", "user.email", "fixture@example.invalid")
        git(self.canonical, "config", "user.name", "Fixture")
        (self.canonical / "README.md").write_text("fixture\n", encoding="utf-8")
        git(self.canonical, "add", "README.md")
        git(self.canonical, "commit", "-qm", "fixture: initial")
        git(self.canonical, "push", "-q", "origin", "HEAD:refs/heads/main")
        git(self.canonical, "fetch", "-q", "origin")
        # Rewrite the remote only after fetching: the slug the pass reads must look
        # like GitHub, while the fixture itself must stay a local path to clone from.
        git(self.canonical, "config", "remote.origin.url", f"git@github.com:{SLUG}.git")
        self.worktree = self.root / "repo-gh4242"
        git(self.canonical, "worktree", "add", "-q", "--detach", str(self.worktree), "HEAD")
        self.census = {Path.cwd()}
        self.finished = {("gh", 4242, SLUG): (True, "issue-4242-closed")}

    def decide(self, path=None, census="default", cache=None):
        return reclaim.evidence(path or self.worktree,
                                self.census if census == "default" else census,
                                self.finished if cache is None else cache)

    def test_authorizes_finished_clean_and_pushed_worktree(self):
        verdict = self.decide()
        self.assertTrue(verdict["authorized"], verdict)
        self.assertEqual(verdict["reason"], "work-finished")

    def test_refuses_without_a_process_inventory(self):
        verdict = self.decide(census=None)
        self.assertFalse(verdict["authorized"])
        self.assertEqual(verdict["reason"], "process-inventory-unavailable")

    def test_refuses_a_path_that_is_not_a_worktree(self):
        plain = self.root / "plain-gh4242"
        plain.mkdir()
        verdict = self.decide(path=plain)
        self.assertEqual(verdict["reason"], "not-a-worktree")

    def test_refuses_when_the_name_encodes_no_reference(self):
        unnamed = self.root / "repo-manual"
        git(self.canonical, "worktree", "add", "-q", "--detach", str(unnamed), "HEAD")
        verdict = self.decide(path=unnamed)
        self.assertEqual(verdict["reason"], "reference-unknown")

    def test_refuses_while_the_issue_remains_open(self):
        verdict = self.decide(cache={("gh", 4242, SLUG): (False, "issue-4242-open")})
        self.assertFalse(verdict["authorized"])
        self.assertEqual(verdict["reason"], "issue-4242-open")

    def test_refuses_every_reference_a_name_encodes(self):
        both = self.root / "repo-pr9001-review-gh4242"
        git(self.canonical, "worktree", "add", "-q", "--detach", str(both), "HEAD")
        cache = dict(self.finished)
        cache[("pr", 9001, SLUG)] = (False, "pr-9001-closed")
        verdict = self.decide(path=both, cache=cache)
        self.assertEqual(verdict["reason"], "pr-9001-closed")

    def test_refuses_when_a_live_process_works_inside_the_worktree(self):
        verdict = self.decide(census={self.worktree / "nested"})
        self.assertEqual(verdict["reason"], "writers-present")

    def test_refuses_uncommitted_changes(self):
        (self.worktree / "README.md").write_text("edited\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_untracked_files(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_unpushed_commits(self):
        (self.worktree / "README.md").write_text("changed\n", encoding="utf-8")
        git(self.worktree, "add", "README.md")
        git(self.worktree, "commit", "-qm", "fixture: unpushed")
        self.assertEqual(self.decide()["reason"], "unpushed-commits-1")

    def test_removes_an_authorized_worktree(self):
        removed, detail = reclaim.remove(self.worktree)
        self.assertTrue(removed, detail)
        self.assertFalse(self.worktree.exists())

    def test_reports_without_removing_when_apply_is_absent(self):
        result = subprocess.run(  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(SCRIPTS / "worktree-reclaim-finished.py"),
             "--base-dir", str(self.root), "--budget-seconds", "30"],
            check=True, capture_output=True, text=True)
        self.assertIn('"dry_run": true', result.stdout)
        self.assertTrue(self.worktree.exists())


if __name__ == "__main__":
    unittest.main()
