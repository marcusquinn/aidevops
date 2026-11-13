#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fixture-only reclaim evidence tests: every incomplete signal must refuse removal."""

import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed offline Git fixtures only.
import sys
import tempfile
import unittest

LIFECYCLE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LIFECYCLE))
GIT = shutil.which("git")
if not GIT:
    raise RuntimeError("Git is required for fixture verification")

from worker_lifecycle.reclaim import evidence as collector  # noqa: E402
from worker_lifecycle.reclaim import host  # noqa: E402
from worker_lifecycle.reclaim import sweep as reclaim  # noqa: E402

SLUG = "fixture/repo"
ORIGIN = f"git@github.com:{SLUG}.git"


def git(path, *arguments):
    subprocess.run([GIT, "-C", str(path), *arguments], check=True,  # nosec B603
                   capture_output=True, text=True)


def census_of(*directories):
    return host.Census(frozenset(Path(directory) for directory in directories), ())


class ReferenceTests(unittest.TestCase):
    def test_extracts_issue_and_pull_request_numbers(self):
        self.assertEqual(collector.references("repo-feature-auto-20261112-gh22419"),
                         [("gh", 22419)])
        self.assertEqual(collector.references("repo-pr36801-ci-repair-abc"), [("pr", 36801)])

    def test_extracts_adjacent_references_sharing_a_separator(self):
        self.assertEqual(collector.references("repo-gh42-pr9001"),
                         [("gh", 42), ("pr", 9001)])

    def test_extracts_single_digit_references(self):
        self.assertEqual(collector.references("repo-gh7"), [("gh", 7)])

    def test_reports_no_reference_when_name_encodes_none(self):
        self.assertEqual(collector.references("repo-manual-investigation"), [])

    def test_ignores_digits_that_merely_follow_letters(self):
        self.assertEqual(collector.references("sprint2-release"), [])


class RepositoryTests(unittest.TestCase):
    def test_accepts_github_remotes_only(self):
        self.assertIsNotNone(collector.REMOTE_SLUG.search(ORIGIN))
        self.assertIsNotNone(collector.REMOTE_SLUG.search(f"https://github.com/{SLUG}"))
        self.assertIsNone(collector.REMOTE_SLUG.search(f"git@gitlab.example:{SLUG}.git"))


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="reclaim-fixture-")).resolve()
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
        git(self.canonical, "config", "remote.origin.url", ORIGIN)
        self.worktree = self.add_worktree("repo-gh4242")
        self.census = census_of(Path.cwd())
        self.finished = {("gh", 4242, SLUG): (True, "issue-4242-closed")}

    def add_worktree(self, name):
        path = self.root / name
        git(self.canonical, "worktree", "add", "-q", "--detach", str(path), "HEAD")
        return path

    def decide(self, path=None, census="default", cache=None):
        return collector.evidence(path or self.worktree,
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
        self.assertEqual(self.decide(path=plain)["reason"], "not-a-linked-worktree")

    def test_refuses_a_main_checkout(self):
        # A main checkout has a .git directory, so it must never be a candidate.
        self.assertEqual(self.decide(path=self.canonical)["reason"],
                         "not-a-linked-worktree")

    def test_refuses_a_locked_worktree(self):
        git(self.canonical, "worktree", "lock", str(self.worktree))
        self.assertEqual(self.decide()["reason"], "worktree-locked")

    def test_refuses_a_symlinked_candidate(self):
        link = self.root / "linked-gh4242"
        link.symlink_to(self.worktree)
        self.assertEqual(self.decide(path=link)["reason"], "symlinked-path")

    def test_refuses_when_the_name_encodes_no_reference(self):
        unnamed = self.add_worktree("repo-manual")
        self.assertEqual(self.decide(path=unnamed)["reason"], "reference-unknown")

    def test_refuses_a_remote_outside_github(self):
        git(self.canonical, "config", "remote.origin.url", f"git@gitlab.example:{SLUG}.git")
        self.assertEqual(self.decide()["reason"], "repository-unknown")

    def test_refuses_while_the_issue_remains_open(self):
        verdict = self.decide(cache={("gh", 4242, SLUG): (False, "issue-4242-open")})
        self.assertFalse(verdict["authorized"])
        self.assertEqual(verdict["reason"], "issue-4242-open")

    def test_refuses_every_reference_a_name_encodes(self):
        both = self.add_worktree("repo-pr9001-gh4242")
        cache = dict(self.finished)
        cache[("pr", 9001, SLUG)] = (False, "pr-9001-closed")
        self.assertEqual(self.decide(path=both, cache=cache)["reason"], "pr-9001-closed")

    def test_refuses_when_a_live_process_works_inside_the_worktree(self):
        self.assertEqual(self.decide(census=census_of(self.worktree / "nested"))["reason"],
                         "writers-present")

    def test_refuses_when_a_live_process_names_the_worktree(self):
        census = host.Census(frozenset({Path.cwd()}), (f"--repo-path={self.worktree}",))
        self.assertEqual(self.decide(census=census)["reason"], "writers-present")

    def test_refuses_uncommitted_changes(self):
        (self.worktree / "README.md").write_text("edited\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_untracked_files(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_authorizes_when_only_the_cleanup_deferred_marker_is_untracked(self):
        marker = self.worktree / ".agents" / ".full-loop-cleanup-deferred"
        marker.parent.mkdir(exist_ok=True)
        marker.write_text("deferred\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "work-finished")

    def test_refuses_the_marker_alongside_another_untracked_file(self):
        marker = self.worktree / ".agents" / ".full-loop-cleanup-deferred"
        marker.parent.mkdir(exist_ok=True)
        marker.write_text("deferred\n", encoding="utf-8")
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_a_tracked_modification_of_the_marker_path(self):
        marker = self.worktree / ".agents" / ".full-loop-cleanup-deferred"
        marker.parent.mkdir(exist_ok=True)
        marker.write_text("deferred\n", encoding="utf-8")
        git(self.worktree, "add", "-f", str(marker))
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_untracked_files_hidden_by_configuration(self):
        git(self.worktree, "config", "status.showUntrackedFiles", "no")
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_unpushed_commits(self):
        (self.worktree / "README.md").write_text("changed\n", encoding="utf-8")
        git(self.worktree, "add", "README.md")
        git(self.worktree, "commit", "-qm", "fixture: unpushed")
        self.assertEqual(self.decide()["reason"], "unpushed-commits-1")

    def test_ignores_an_inherited_git_directory_variable(self):
        # An inherited GIT_DIR would otherwise answer every question from another
        # checkout, reporting a dirty candidate as clean.
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        previous = os.environ.get("GIT_DIR")
        os.environ["GIT_DIR"] = str(self.origin)
        self.addCleanup(lambda: os.environ.pop("GIT_DIR", None) if previous is None
                        else os.environ.__setitem__("GIT_DIR", previous))
        self.assertEqual(self.decide()["reason"], "uncommitted-changes")

    def test_refuses_a_main_checkout_with_a_separate_git_directory(self):
        # --separate-git-dir gives a main checkout the same .git file shape, so only
        # registration distinguishes it from a linked worktree.
        separate = self.root / "separate-gh4242"
        subprocess.run([GIT, "init", "-q", "--separate-git-dir",  # nosec B603
                        str(self.root / "separate.git"), str(separate)],
                       check=True, capture_output=True)
        self.assertEqual(self.decide(path=separate)["reason"], "not-a-linked-worktree")
        removed, detail = host.remove(separate, collector.nothing_to_lose)
        self.assertFalse(removed)
        self.assertEqual(detail, "not-a-linked-worktree")
        self.assertTrue(separate.exists())

    def test_accepts_relative_worktree_links_from_another_directory(self):
        # Git resolves both pointers relatively; judgement must not depend on cwd.
        metadata = host.metadata_directory(self.worktree)
        self.assertIsNotNone(metadata)
        marker = self.worktree / ".git"
        relative_back = os.path.relpath(marker, metadata)
        (metadata / "gitdir").write_text(f"{relative_back}\n", encoding="utf-8")
        marker.write_text(f"gitdir: {os.path.relpath(metadata, self.worktree)}\n",
                          encoding="utf-8")
        origin = Path.cwd()
        try:
            os.chdir(self.root)
            self.assertEqual(host.metadata_directory(self.worktree), metadata)
            self.assertEqual(self.decide()["reason"], "work-finished")
        finally:
            os.chdir(origin)

    def test_removal_refuses_a_locked_worktree(self):
        git(self.canonical, "worktree", "lock", str(self.worktree))
        removed, detail = host.remove(self.worktree, collector.nothing_to_lose)
        self.assertFalse(removed)
        self.assertEqual(detail, "worktree-locked")
        self.assertTrue(self.worktree.exists())

    def test_removes_an_authorized_worktree(self):
        removed, detail = host.remove(self.worktree, collector.nothing_to_lose)
        self.assertTrue(removed, detail)
        self.assertFalse(self.worktree.exists())

    def test_refuses_removal_when_state_changed_after_judgement(self):
        (self.worktree / "notes.md").write_text("late\n", encoding="utf-8")
        removed, detail = host.remove(self.worktree, collector.nothing_to_lose)
        self.assertFalse(removed)
        self.assertEqual(detail, "changed-uncommitted-changes")
        self.assertTrue(self.worktree.exists())

    def test_reports_without_removing_when_apply_is_absent(self):
        result = subprocess.run(  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(LIFECYCLE / "worktree-reclaim.py"),
             "--base-dir", str(self.root), "--budget-seconds", "30"],
            check=True, capture_output=True, text=True)
        self.assertIn('"dry_run": true', result.stdout)
        self.assertTrue(self.worktree.exists())


class BatchTests(unittest.TestCase):
    def run_with(self, status, output):
        original = collector.run
        self.commands = []
        def record(command, timeout=60):
            self.commands.append(command)
            return (status, output)
        collector.run = record
        self.addCleanup(setattr, collector, "run", original)

    def test_repository_identity_is_bound_as_variables_not_query_text(self):
        # A slug can carry a quote, and a slug parsed as query syntax is an injection.
        self.run_with(0, '{"data":{"repository":{"g1":{"state":"CLOSED"}}}}')
        hostile = 'owner", name: "other'
        collector.prefetch({f'{hostile}/repo': [("gh", 1)]}, {})
        command = self.commands[0]
        query = next(argument.partition("=")[2] for argument in command
                     if argument.startswith("query="))
        self.assertNotIn(hostile, query)
        self.assertIn("$owner", query)
        self.assertIn(f"owner={hostile}", command)
        self.assertEqual(command[command.index(f"owner={hostile}") - 1], "-f")
        self.assertEqual(command[command.index("name=repo") - 1], "-f")

    def test_batch_populates_cache_and_tolerates_nonzero_exit(self):
        self.run_with(1, '{"data":{"repository":{"g1":{"state":"CLOSED"},'
                         '"p2":{"state":"OPEN"},"g3":null}},"errors":[{}]}')
        cache = {}
        collector.prefetch({SLUG: [("gh", 1), ("pr", 2), ("gh", 3)]}, cache)
        self.assertEqual(cache[("gh", 1, SLUG)], (True, "issue-1-closed"))
        self.assertEqual(cache[("pr", 2, SLUG)], (False, "pr-2-open"))
        self.assertNotIn(("gh", 3, SLUG), cache)

    def test_failed_batch_leaves_cache_for_per_reference_fallback(self):
        self.run_with(1, "not json")
        cache = {}
        collector.prefetch({SLUG: [("gh", 1)]}, cache)
        self.assertEqual(cache, {})

    def test_free_space_accounting(self):
        self.assertEqual(reclaim.reclaimed_bytes(100, 350, 2), 250)
        self.assertEqual(reclaim.reclaimed_bytes(100, 350, 0), 0)
        self.assertEqual(reclaim.reclaimed_bytes(None, 350, 2), 0)
        self.assertEqual(reclaim.reclaimed_bytes(350, 100, 2), 0)


if __name__ == "__main__":
    unittest.main()
