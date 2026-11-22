#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fixture-only reclaim evidence tests: every incomplete signal must refuse removal."""

import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed offline Git fixtures only.
import sys
import tempfile
import time
import unittest

LIFECYCLE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LIFECYCLE))
GIT = shutil.which("git")
if not GIT:
    raise RuntimeError("Git is required for fixture verification")

from worker_lifecycle.reclaim import archive as archive_stage  # noqa: E402
from worker_lifecycle.reclaim import decision  # noqa: E402
from worker_lifecycle.reclaim import evidence as collector  # noqa: E402
from worker_lifecycle.reclaim import host  # noqa: E402
from worker_lifecycle.reclaim import progress  # noqa: E402
from worker_lifecycle.reclaim import review  # noqa: E402
from worker_lifecycle.reclaim import sweep as reclaim  # noqa: E402
from worker_lifecycle.storage import LifecycleRegistry  # noqa: E402

SLUG = "fixture/repo"
ORIGIN = f"git@github.com:{SLUG}.git"


def git(path, *arguments):
    subprocess.run([GIT, "-C", str(path), *arguments], check=True,  # nosec B603
                   capture_output=True, text=True)


def no_owner(path):
    return None


def owner_reporting(reason):
    return lambda path: reason


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


class GitFixture(unittest.TestCase):
    """A bare origin, a canonical clone and one finished linked worktree."""

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
        self.finished = {("gh", 4242, SLUG): (True, "issue-4242-closed")}

    def add_worktree(self, name):
        path = self.root / name
        git(self.canonical, "worktree", "add", "-q", "--detach", str(path), "HEAD")
        return path

    def decide(self, path=None, owner=no_owner, cache=None):
        return collector.evidence(path or self.worktree, owner,
                                  self.finished if cache is None else cache)


class EvidenceTests(GitFixture):
    def test_authorizes_finished_clean_and_pushed_worktree(self):
        verdict = self.decide()
        self.assertTrue(verdict["authorized"], verdict)
        self.assertEqual(verdict["reason"], "work-finished")

    def test_refuses_without_owner_observation(self):
        verdict = self.decide(owner=None)
        self.assertFalse(verdict["authorized"])
        self.assertEqual(verdict["reason"], "owner-observation-unavailable")

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

    def test_refuses_while_a_registered_owner_is_alive(self):
        self.assertEqual(self.decide(owner=owner_reporting("owner-alive"))["reason"],
                         "owner-alive")

    def test_refuses_when_ownership_is_unreadable(self):
        for reason in ("owner-unobservable", "owner-not-enrolled",
                       "owner-registry-unreadable"):
            self.assertEqual(self.decide(owner=owner_reporting(reason))["reason"], reason)

    def test_reads_owners_only_for_finished_work(self):
        asked = []
        cache = {("gh", 4242, SLUG): (False, "issue-4242-open")}
        self.decide(owner=asked.append, cache=cache)
        self.assertEqual(asked, [])

    def worktree_idle(self, name, idle=review.IDLE_SECONDS + 60):
        """Add a worktree whose Git HEAD and index were last touched ``idle`` ago."""
        tree = self.add_worktree(name)
        metadata = host.metadata_directory(tree)
        self.assertIsNotNone(metadata)
        moment = time.time() - idle
        for entry in ("HEAD", "index"):
            if (metadata / entry).exists():
                os.utime(metadata / entry, (moment, moment))
        return tree

    OPEN_REVIEW = {("pr", 9001, SLUG): (False, "pr-9001-open")}

    def test_authorizes_an_idle_review_tree_of_an_open_pull_request(self):
        tree = self.worktree_idle("repo-pr9001-review-fixture")
        verdict = self.decide(path=tree, cache=self.OPEN_REVIEW)
        self.assertTrue(verdict["authorized"], verdict)
        self.assertEqual(verdict["reason"], "review-idle")

    def test_dirty_idle_review_tree_is_refused_not_archived(self):
        # Its PR is still open, so local state is not finished work to preserve.
        tree = self.worktree_idle("repo-pr9001-review-fixture")
        (tree / "notes.md").write_text("local\n", encoding="utf-8")
        verdict = self.decide(path=tree, cache=self.OPEN_REVIEW)
        self.assertFalse(verdict["finished"], verdict)
        self.assertEqual(decision.classify(verdict), (decision.REFUSE, "uncommitted-changes"))

    def test_refuses_a_recently_active_review_tree(self):
        tree = self.worktree_idle("repo-pr9001-review-fixture", idle=60)
        self.assertEqual(self.decide(path=tree, cache=self.OPEN_REVIEW)["reason"],
                         "pr-9001-open")

    def test_refuses_an_idle_review_tree_with_a_live_owner(self):
        tree = self.worktree_idle("repo-pr9001-review-fixture")
        verdict = self.decide(path=tree, cache=self.OPEN_REVIEW,
                              owner=owner_reporting("owner-alive"))
        self.assertEqual(verdict["reason"], "owner-alive")

    def test_refuses_an_idle_review_tree_with_unknown_pull_request_state(self):
        tree = self.worktree_idle("repo-pr9001-review-fixture")
        verdict = self.decide(path=tree, cache={("pr", 9001, SLUG): (False, "pr-9001-none")})
        self.assertEqual(verdict["reason"], "pr-9001-none")

    OPEN_ISSUE = {("gh", 4242, SLUG): (False, "issue-4242-open")}
    WORKER = "repo-feature-auto-20261114-023500-gh4242"

    def test_authorizes_an_idle_worker_tree_of_an_open_issue(self):
        tree = self.worktree_idle(self.WORKER, idle=review.WORKER_IDLE_SECONDS + 60)
        verdict = self.decide(path=tree, cache=self.OPEN_ISSUE)
        self.assertTrue(verdict["authorized"], verdict)
        self.assertEqual(verdict["reason"], "worker-idle")

    def test_refuses_a_worker_tree_idle_under_six_hours(self):
        tree = self.worktree_idle(self.WORKER, idle=review.IDLE_SECONDS + 60)
        self.assertEqual(self.decide(path=tree, cache=self.OPEN_ISSUE)["reason"],
                         "issue-4242-open")

    def test_idle_worker_tree_removal_recheck_refuses_when_active(self):
        tree = self.worktree_idle(self.WORKER, idle=60)
        self.assertEqual(review.idle_verifier("worker-idle")(tree), (False, "worker-active"))

    def test_authorizes_an_idle_unreferenced_tree_only_after_72_hours(self):
        name = "repo-feature-auto-20261114-023500-4321"
        tree = self.worktree_idle(name, idle=review.UNREFERENCED_IDLE_SECONDS + 60)
        verdict = self.decide(path=tree)
        self.assertTrue(verdict["authorized"], verdict)
        self.assertEqual(verdict["reason"], "unreferenced-idle")
        recent = self.worktree_idle("repo-feature-auto-20261114-023501-4322",
                                    idle=review.WORKER_IDLE_SECONDS + 60)
        self.assertEqual(self.decide(path=recent)["reason"], "reference-unknown")

    def test_open_pull_request_still_refuses_outside_review_trees(self):
        tree = self.worktree_idle("repo-pr9001-ci-repair-fixture")
        self.assertEqual(self.decide(path=tree, cache=self.OPEN_REVIEW)["reason"],
                         "pr-9001-open")

    def test_review_exception_follows_the_trees_own_pull_request_only(self):
        # An open issue earlier in the name must not stand in for PR 9001's state.
        tree = self.worktree_idle("repo-gh4242-pr9001-review-fixture")
        cache = {("gh", 4242, SLUG): (False, "issue-4242-open"),
                 ("pr", 9001, SLUG): (False, "pr-9001-none")}
        self.assertEqual(self.decide(path=tree, cache=cache)["reason"], "issue-4242-open")
        own = self.worktree_idle("repo-pr9001-review-gh4242-fixture")
        self.assertEqual(self.decide(path=own, cache=cache)["reason"], "pr-9001-none")

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
        removed, detail = host.remove(separate, host.nothing_to_lose, no_owner)
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
        removed, detail = host.remove(self.worktree, host.nothing_to_lose, no_owner)
        self.assertFalse(removed)
        self.assertEqual(detail, "worktree-locked")
        self.assertTrue(self.worktree.exists())

    def test_removes_an_authorized_worktree(self):
        removed, detail = host.remove(self.worktree, host.nothing_to_lose, no_owner)
        self.assertTrue(removed, detail)
        self.assertFalse(self.worktree.exists())

    def test_refuses_removal_when_an_owner_appeared_after_judgement(self):
        removed, detail = host.remove(self.worktree, host.nothing_to_lose,
                                      owner_reporting("owner-alive"))
        self.assertFalse(removed)
        self.assertEqual(detail, "owners-appeared")
        self.assertTrue(self.worktree.exists())

    def test_refuses_removal_when_state_changed_after_judgement(self):
        (self.worktree / "notes.md").write_text("late\n", encoding="utf-8")
        removed, detail = host.remove(self.worktree, host.nothing_to_lose, no_owner)
        self.assertFalse(removed)
        self.assertEqual(detail, "changed-uncommitted-changes")
        self.assertTrue(self.worktree.exists())

    def test_unreadable_registry_refuses_every_candidate(self):
        result = subprocess.run(  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(LIFECYCLE / "worktree-reclaim.py"),
             "--base-dir", str(self.root), "--state-dir", str(self.root / "no-registry"),
             "--apply", "--budget-seconds", "30"],
            check=True, capture_output=True, text=True)
        # An unreadable registry refuses every candidate, even with --apply.
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["owner_observation"], "unavailable")
        self.assertEqual(receipt["residual_risk"], "unregistered-processes-unobserved")
        self.assertEqual(receipt["removed"], 0)
        self.assertTrue(self.worktree.exists())


class StoreOwner:
    """A registered-owner check with no live owner, backed by a real registry."""

    def __init__(self, store):
        self.store = store

    def __call__(self, path):
        return None


class DecisionTests(GitFixture):
    """Three-way decision, fingerprint CAS and journaled authorization (GH#38348)."""

    def setUp(self):
        super().setUp()
        self.store = LifecycleRegistry.initialize(self.root / "state")

    def a_pass(self, *, apply_removal=True, owner=None):
        return reclaim.Pass(owner=owner if owner is not None else StoreOwner(self.store),
                            apply_removal=apply_removal,
                            deadline=time.monotonic() + 120, finished=dict(self.finished))

    def reclaim_events(self):
        with self.store.connection() as connection:
            return [row[0] for row in connection.execute(
                "SELECT json_extract(payload,'$.type') FROM events WHERE "
                "json_extract(payload,'$.type') LIKE 'reclaim-%' ORDER BY sequence")]

    def test_classifies_remove_archive_and_refuse(self):
        self.assertEqual(decision.classify(self.decide())[0], decision.REMOVE)
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertEqual(decision.classify(self.decide()),
                         (decision.ARCHIVE, "uncommitted-changes"))
        live = self.decide(owner=owner_reporting("owner-alive"))
        self.assertEqual(decision.classify(live), (decision.REFUSE, "owner-alive"))
        open_issue = self.decide(cache={("gh", 4242, SLUG): (False, "issue-4242-open")})
        self.assertEqual(decision.classify(open_issue)[0], decision.REFUSE)

    def test_unpushed_finished_work_is_archived(self):
        (self.worktree / "README.md").write_text("changed\n", encoding="utf-8")
        git(self.worktree, "add", "README.md")
        git(self.worktree, "commit", "-qm", "fixture: unpushed")
        self.assertEqual(decision.classify(self.decide()),
                         (decision.ARCHIVE, "unpushed-commits-1"))

    def test_unreadable_state_is_never_archived(self):
        for reason in ("status-unreadable", "unpushed-state-unreadable",
                       "unpushed-commits-0", "unpushed-commits-x"):
            verdict = {"authorized": False, "finished": True, "reason": reason}
            self.assertEqual(decision.classify(verdict)[0], decision.REFUSE, reason)

    def test_fingerprint_tracks_head_and_status(self):
        first = decision.fingerprint(self.worktree)
        self.assertIsNotNone(first)
        self.assertEqual(decision.fingerprint(self.worktree), first)
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        self.assertNotEqual(decision.fingerprint(self.worktree), first)
        self.assertIsNone(decision.fingerprint(self.root / "absent"))

    def move_to_other_pushed_work(self):
        """Move the worktree's HEAD to different work that is clean and pushed."""
        (self.canonical / "OTHER.md").write_text("other\n", encoding="utf-8")
        git(self.canonical, "add", "OTHER.md")
        git(self.canonical, "commit", "-qm", "fixture: other")
        # The origin URL is a GitHub-shaped placeholder, so mark the commit as
        # pushed through the remote-tracking ref rather than a real push.
        git(self.canonical, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(self.worktree, "checkout", "-q", "--detach", "origin/main")
        self.assertEqual(host.nothing_to_lose(self.worktree), (True, "nothing-to-lose"))

    def test_removal_refuses_when_head_moved_to_other_clean_pushed_work(self):
        digest = decision.fingerprint(self.worktree)
        self.move_to_other_pushed_work()
        removed, detail = host.remove(
            self.worktree, decision.cas_verify(digest, host.nothing_to_lose), no_owner)
        self.assertFalse(removed)
        self.assertEqual(detail, "evidence-changed")
        self.assertTrue(self.worktree.exists())

    def test_head_moved_during_judgement_refuses_removal(self):
        original = reclaim.evidence

        def moving(*arguments, **options):
            self.move_to_other_pushed_work()
            return original(*arguments, **options)

        reclaim.evidence = moving
        try:
            receipt = reclaim.new_receipt(self.root, dry_run=False)
            reclaim.reclaim_one(self.worktree, self.a_pass(), receipt)
        finally:
            reclaim.evidence = original
        self.assertEqual(receipt["results"][0]["removal"], "evidence-changed")
        self.assertTrue(self.worktree.exists())

    def test_fingerprint_distinguishes_a_recreated_tree(self):
        digest = decision.fingerprint(self.worktree)
        aside = self.root / "aside"
        os.rename(self.worktree, aside)
        # Copy while the original still exists, so the new directory has its own inode.
        shutil.copytree(aside, self.worktree, symlinks=True)
        try:
            self.assertIsNotNone(decision.fingerprint(self.worktree))
            self.assertNotEqual(decision.fingerprint(self.worktree), digest)
        finally:
            shutil.rmtree(aside)

    def test_fingerprint_stops_when_the_budget_is_spent(self):
        self.assertIsNone(decision.fingerprint(self.worktree, remaining=lambda: 0))

    def test_dry_run_reports_decisions_and_writes_nothing(self):
        receipt = reclaim.new_receipt(self.root, dry_run=True)
        self.assertIsNone(reclaim.reclaim_one(self.worktree, self.a_pass(apply_removal=False),
                                              receipt))
        self.assertEqual(receipt["results"][0]["decision"], decision.REMOVE)
        self.assertEqual(self.reclaim_events(), [])
        self.assertTrue(self.worktree.exists())

    def test_applied_removal_journals_once_and_replays_idempotently(self):
        receipt = reclaim.new_receipt(self.root, dry_run=False)
        reclaim.reclaim_one(self.worktree, self.a_pass(), receipt)
        verdict = receipt["results"][0]
        self.assertEqual(verdict["removal"], "removed", verdict)
        self.assertNotIn("journal", verdict)
        self.assertFalse(self.worktree.exists())
        self.assertEqual(self.reclaim_events(), [decision.AUTHORIZED, decision.REMOVED])
        for kind in (decision.AUTHORIZED, decision.REMOVED):
            self.assertIsNone(decision.record(self.store, kind, verdict, verdict["fingerprint"]))
        self.assertEqual(self.reclaim_events(), [decision.AUTHORIZED, decision.REMOVED])

    def test_archive_candidates_are_queued_not_removed_or_journaled(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        receipt = reclaim.new_receipt(self.root, dry_run=False)
        reclaim.reclaim_one(self.worktree, self.a_pass(), receipt)
        self.assertEqual((receipt["archive_queued"], receipt["refused"], receipt["removed"]),
                         (1, 0, 0))
        self.assertEqual(self.reclaim_events(), [])
        self.assertTrue(self.worktree.exists())

    def test_removal_refuses_without_a_journal(self):
        receipt = reclaim.new_receipt(self.root, dry_run=False)
        reclaim.reclaim_one(self.worktree, self.a_pass(owner=no_owner), receipt)
        self.assertEqual(receipt["results"][0]["removal"], "journal-unavailable")
        self.assertEqual(receipt["failed"], 1)
        self.assertTrue(self.worktree.exists())

    def test_reclaim_events_are_archived_after_retention(self):
        receipt = reclaim.new_receipt(self.root, dry_run=False)
        reclaim.reclaim_one(self.worktree, self.a_pass(), receipt)
        result = self.store.compact(age=0, apply=True)
        self.assertGreaterEqual(result["archived_events"], 2)
        self.assertEqual(self.reclaim_events(), [])
        verdict = receipt["results"][0]
        # Archived event IDs keep replay idempotent through the digest tombstone.
        self.assertIsNone(decision.record(self.store, decision.REMOVED, verdict,
                                          verdict["fingerprint"]))


class ArchiveStageTests(GitFixture):
    """Stage 2: archive with commits bundled, verify, journal, then remove (GH#38394)."""

    a_pass = DecisionTests.a_pass
    reclaim_events = DecisionTests.reclaim_events

    def setUp(self):
        super().setUp()
        self.store = LifecycleRegistry.initialize(self.root / "state")
        self.archives = self.root / "archives"
        previous = os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT")
        os.environ["AIDEVOPS_WORKTREE_ARCHIVE_ROOT"] = str(self.archives)
        self.addCleanup(self.restore_environment, previous)
        git(self.canonical, "remote", "set-head", "origin", "main")

    @staticmethod
    def restore_environment(previous):
        if previous is None:
            os.environ.pop("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", None)
        else:
            os.environ["AIDEVOPS_WORKTREE_ARCHIVE_ROOT"] = previous

    def publish_commit_and_dirty(self):
        """Commit work whose branch is on origin, then leave an uncommitted file."""
        (self.worktree / "README.md").write_text("published\n", encoding="utf-8")
        git(self.worktree, "commit", "-qam", "fixture: published")
        # Refs are shared with the canonical clone: this marks the commit as pushed.
        git(self.worktree, "update-ref", "refs/remotes/origin/feature", "HEAD")
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")

    def run_pass(self, current):
        receipt = reclaim.new_receipt(self.root, dry_run=not current.apply_removal)
        reclaim.reclaim_one(self.worktree, current, receipt)
        return receipt, archive_stage.stage_two(current.queued, current, receipt)

    def manifests(self):
        return [json.loads(path.read_text(encoding="utf-8"))
                for path in self.archives.rglob("manifest.json")]

    def test_finished_tree_with_local_state_is_archived_then_removed(self):
        self.publish_commit_and_dirty()
        receipt, repositories = self.run_pass(self.a_pass())
        verdict = receipt["results"][0]
        self.assertEqual(verdict["removal"], "removed", verdict)
        self.assertEqual((receipt["archived"], receipt["removed"], receipt["failed"]), (1, 1, 0))
        self.assertFalse(self.worktree.exists())
        self.assertEqual(len(repositories), 1)
        self.assertEqual(self.reclaim_events(), [decision.ARCHIVED, decision.REMOVED])
        # The branch is on origin, yet the archive carries its commits (#38056).
        archive = Path(verdict["archive"]["path"])
        self.assertTrue((archive / "commits.bundle").is_file())
        self.assertEqual([m["remote_branch_state"] for m in self.manifests()], ["bundled"])

    def archive_then_write(self, name, content):
        """Run one pass that writes ``name`` right after the archive is captured."""
        original = archive_stage.capture

        def late_write(*arguments, **options):
            result = original(*arguments, **options)
            (self.worktree / name).write_text(content, encoding="utf-8")
            return result

        archive_stage.capture = late_write
        try:
            receipt, _ = self.run_pass(self.a_pass())
        finally:
            archive_stage.capture = original
        self.assertEqual((receipt["removed"], receipt["failed"]), (0, 1))
        self.assertTrue(self.worktree.exists())
        self.assertEqual(len(self.manifests()), 1)
        self.assertEqual(self.reclaim_events(), [decision.ARCHIVED])
        return receipt["results"][0]["removal"]

    def test_new_file_after_archive_keeps_tree_and_archive(self):
        self.publish_commit_and_dirty()
        self.assertEqual(self.archive_then_write("late.md", "late\n"), "evidence-changed")

    def test_content_change_status_cannot_see_is_caught_by_source_matches(self):
        # Rewriting an already-untracked file leaves porcelain status unchanged,
        # so only the archive comparison can refuse this removal.
        self.publish_commit_and_dirty()
        self.assertEqual(self.archive_then_write("notes.md", "rewritten\n"),
                         "changed-" + archive_stage.SOURCE_CHANGED)

    def test_archive_failure_keeps_tree_and_is_deferrable(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        original = archive_stage.run_helper

        def failing(*arguments, **options):
            raise subprocess.CalledProcessError(1, ["worktree-archive-helper.sh"], b"", b"boom")

        archive_stage.run_helper = failing
        try:
            receipt, _ = self.run_pass(self.a_pass())
        finally:
            archive_stage.run_helper = original
        verdict = receipt["results"][0]
        self.assertEqual(verdict["removal"], "archive-failed")
        self.assertEqual(receipt["failed"], 1)
        self.assertTrue(self.worktree.exists())
        self.assertEqual(self.reclaim_events(), [])
        self.assertTrue(progress.unreadable(verdict))
        self.assertFalse(progress.unreadable({"removal": "archive-capacity"}))
        # A repeatedly timed-out archive backs off instead of blocking the queue.
        self.assertTrue(progress.unreadable({"removal": "archive-timeout"}))

    def test_unreadable_manifest_fails_one_tree_without_stopping_the_pass(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        original = archive_stage.archive_id

        def unreadable_manifest(archive):
            raise PermissionError("manifest.json")

        archive_stage.archive_id = unreadable_manifest
        try:
            receipt, _ = self.run_pass(self.a_pass())
        finally:
            archive_stage.archive_id = original
        verdict = receipt["results"][0]
        self.assertEqual((verdict["removal"], receipt["failed"]),
                         ("archive-verify-failed", 1))
        self.assertTrue(self.worktree.exists())
        self.assertEqual(self.reclaim_events(), [])

    def test_budget_spent_by_base_lookup_never_starts_an_archive(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        current = self.a_pass()
        original = archive_stage._base_branch

        def slow_lookup(path, timeout):
            # The lookup consumes the budget the stage-two admission saw.
            object.__setattr__(current, "deadline",
                               time.monotonic() + archive_stage.MIN_SECONDS - 5)
            return original(path, timeout)

        archive_stage._base_branch = slow_lookup
        try:
            receipt, _ = self.run_pass(current)
        finally:
            archive_stage._base_branch = original
        self.assertEqual(receipt["results"][0]["removal"], "archive-budget-exhausted")
        self.assertTrue(receipt["budget_exhausted"])
        self.assertEqual(receipt["failed"], 0)
        self.assertFalse(self.archives.exists())
        self.assertTrue(self.worktree.exists())

    def test_dry_run_queues_but_never_archives(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        receipt, repositories = self.run_pass(self.a_pass(apply_removal=False))
        self.assertEqual((receipt["archive_queued"], receipt["archived"]), (1, 0))
        self.assertEqual(repositories, set())
        self.assertFalse(self.archives.exists())
        self.assertEqual(self.reclaim_events(), [])
        self.assertTrue(self.worktree.exists())

    def test_low_budget_never_starts_an_archive(self):
        (self.worktree / "notes.md").write_text("local\n", encoding="utf-8")
        current = reclaim.Pass(owner=StoreOwner(self.store), apply_removal=True,
                               deadline=time.monotonic() + archive_stage.MIN_SECONDS - 5,
                               finished=dict(self.finished))
        receipt, _ = self.run_pass(current)
        self.assertEqual(receipt["results"][0]["removal"], "archive-budget-exhausted")
        self.assertTrue(receipt["budget_exhausted"])
        self.assertFalse(self.archives.exists())
        self.assertTrue(self.worktree.exists())


class ProgressTests(GitFixture):
    """Scan cursor and repeat-unreadable backoff across passes (GH#38376)."""

    def setUp(self):
        super().setUp()
        self.state = Path(tempfile.mkdtemp(prefix="reclaim-state-")).resolve()
        self.addCleanup(shutil.rmtree, self.state, ignore_errors=True)
        self.quarantine = progress.open_quarantine(self.state)

    def a_pass(self, owner, *, apply_removal=True, limit=0):
        return reclaim.Pass(owner=owner, apply_removal=apply_removal, limit=limit,
                            deadline=time.monotonic() + 120, finished=dict(self.finished),
                            quarantine=self.quarantine)

    def judge_once(self, owner, **options):
        receipt = reclaim.new_receipt(self.root, dry_run=not options.get("apply_removal", True))
        reclaim.reclaim_one(self.worktree, self.a_pass(owner, **options), receipt)
        return receipt["results"][0]

    def test_rotation_resumes_after_the_cursor_and_wraps(self):
        paths = [Path(name) for name in ("c", "a", "d", "b")]
        self.assertEqual([p.name for p in progress.ordered(paths, "")], ["a", "b", "c", "d"])
        self.assertEqual([p.name for p in progress.ordered(paths, "b")], ["c", "d", "a", "b"])
        self.assertEqual([p.name for p in progress.ordered(paths, "z")], ["a", "b", "c", "d"])

    def test_cursor_round_trips_and_rejects_anything_but_a_name(self):
        self.assertEqual(progress.read_cursor(self.state), "")
        self.assertTrue(progress.write_cursor(self.state, "repo-gh4242"))
        self.assertEqual(progress.read_cursor(self.state), "repo-gh4242")
        for hostile in ("../escape", "..", 7, ""):
            (self.state / progress.CURSOR_NAME).write_text(json.dumps({"after": hostile}),
                                                          encoding="utf-8")
            self.assertEqual(progress.read_cursor(self.state), "", hostile)
        (self.state / progress.CURSOR_NAME).write_text("not json", encoding="utf-8")
        self.assertEqual(progress.read_cursor(self.state), "")
        self.assertTrue(progress.write_cursor(self.state, "kept"))
        os.chmod(self.state / progress.CURSOR_NAME, 0o644)
        # A cursor anyone could have written is ignored, never followed.
        self.assertEqual(progress.read_cursor(self.state), "")

    def test_repeat_unreadable_refusal_is_deferred_and_readable_state_clears_it(self):
        unreadable = owner_reporting("owner-registry-unreadable")
        first = self.judge_once(unreadable)
        self.assertNotIn("quarantined", first)
        self.assertFalse(self.quarantine.deferred(str(self.worktree)))
        second = self.judge_once(unreadable)
        self.assertTrue(second["quarantined"])
        self.assertTrue(self.quarantine.deferred(str(self.worktree)))
        receipt = reclaim.new_receipt(self.root, dry_run=False)
        seen = list(reclaim.candidates([self.worktree], self.a_pass(unreadable, limit=1),
                                       receipt))
        self.assertEqual((seen, receipt["quarantine_deferred"], receipt["scanned"]), ([], 1, 0))
        # Once readable again, the tree is judged normally and its entry is dropped.
        self.quarantine.entries[str(self.worktree)]["until"] = 0
        self.judge_once(owner_reporting("owner-alive"))
        self.assertNotIn(str(self.worktree), self.quarantine.entries)

    def test_pass_wide_and_network_refusals_are_never_deferred(self):
        for _ in range(3):
            self.judge_once(None)  # owner-observation-unavailable
            self.finished = {("gh", 4242, SLUG): (False, "issue-4242-none")}
            self.judge_once(no_owner)
        self.assertEqual(self.quarantine.entries, {})

    def test_dry_run_records_no_backoff(self):
        for _ in range(3):
            self.judge_once(owner_reporting("owner-unobservable"), apply_removal=False)
        self.assertEqual(self.quarantine.entries, {})

    def test_stopped_pass_names_its_resume_point_and_full_pass_clears_it(self):
        paths = [self.worktree, self.add_worktree("repo-gh4243")]
        receipt = reclaim.new_receipt(self.root, dry_run=True)
        self.assertEqual(list(reclaim.candidates(paths, self.a_pass(None, limit=1), receipt)),
                         paths[:1])
        self.assertEqual(receipt["resume_after"], "repo-gh4242")
        receipt = reclaim.new_receipt(self.root, dry_run=True)
        self.assertEqual(list(reclaim.candidates(paths, self.a_pass(None), receipt)), paths)
        self.assertEqual(receipt["resume_after"], "")

    def test_stalled_prefetch_leaves_budget_for_judgement(self):
        current = reclaim.Pass(owner=None, apply_removal=False,
                               deadline=time.monotonic() + 100)
        granted = []
        original = reclaim.prefetch

        def stalled(wanted, cache, *, remaining):
            granted.append(remaining())
            # Stall for as long as the prefetch share allows.
            time.sleep(min(remaining(), 1.5))

        reclaim.prefetch = stalled
        try:
            reclaim.prefetch_references([self.worktree], current)
        finally:
            reclaim.prefetch = original
        self.assertLessEqual(granted[0], 100 * reclaim.PREFETCH_SHARE)
        self.assertGreater(current.remaining(), 40)
        receipt = reclaim.new_receipt(self.root, dry_run=True)
        self.assertEqual(list(reclaim.candidates([self.worktree], current, receipt)),
                         [self.worktree])

    def run_cli(self, *extra):
        result = subprocess.run(  # nosec B603
            [sys.executable, "-E", "-s", "-B", str(LIFECYCLE / "worktree-reclaim.py"),
             "--base-dir", str(self.root), "--state-dir", str(self.state),
             "--budget-seconds", "60", "--limit", "1", *extra],
            check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def test_limited_applied_passes_advance_through_the_listing(self):
        names = sorted(path.name for path in self.root.iterdir() if path.is_dir())
        first = self.run_cli("--apply")
        second = self.run_cli("--apply")
        self.assertEqual((first["cursor_start"], first["resume_after"]), ("", names[0]))
        self.assertEqual((second["cursor_start"], second["resume_after"]),
                         (names[0], names[1]))
        dry = self.run_cli()
        # A dry run reads the cursor but never moves it.
        self.assertEqual(dry["cursor_start"], names[1])
        self.assertEqual(progress.read_cursor(self.state), names[1])


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
