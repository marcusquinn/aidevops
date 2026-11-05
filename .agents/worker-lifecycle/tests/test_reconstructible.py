"""Remote-recoverable retirement, exclusively using disposable repositories."""

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from tests import test_retirement as fixtures
from worker_lifecycle import legacy_cleanup as cleanup
from worker_lifecycle import legacy_inventory as inventory
from worker_lifecycle.legacy_options import CleanupOptions
from worker_lifecycle.runtime import adapter_for


class ReconstructibleContract(unittest.TestCase):
    git = fixtures.RetirementContract.git

    def setUp(self):
        fixtures.RetirementContract.setUp(self)
        self.base = self.root / "_worktrees"
        self.base.mkdir()
        self.target = self.base / "repository-feature"
        self.git("worktree", "add", "-q", "-b", "feature", str(self.target))
        self.head = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        self.common = self.git("rev-parse", "--absolute-git-dir")
        self.repositories = {self.common: ("fixture/repository", "main")}
        self.item = {"path": str(self.target), "modern": False, "runs": {},
                     "generations": set(), "unbound": True, "last_event": 0}
        self.adapter = adapter_for(self.store.installation_id())
        self.options = CleanupOptions(self.output, apply=True, min_age=0)
        environment = patch.dict(os.environ, {"AIDEVOPS_WORKTREE_BASE_DIR": str(self.base)})
        environment.start()
        self.addCleanup(environment.stop)
        # A synthetic kernel view isolates unrelated runner permission restrictions.
        self.proc = self.root / "proc"
        (self.proc / "self").mkdir(parents=True)
        self.real_census = inventory.require_idle_proc
        census = patch.object(inventory, "require_idle_proc",
                              side_effect=lambda path: self.real_census(path, self.proc))
        census.start()
        self.addCleanup(census.stop)
        prs = patch.object(cleanup, "open_pull_requests", return_value=[])
        self.prs = prs.start()
        self.addCleanup(prs.stop)

    def retire(self):
        return cleanup.process_item(self.store, self.item, self.repositories,
                                    self.adapter, self.options)

    def assert_retained(self, reason):
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retained", result)
        self.assertEqual(result["reason"], reason, result)
        self.assertTrue(self.target.exists())

    def task(self, reference, *, fd=False):
        task = self.proc / "123" / "task" / "124"
        task.mkdir(parents=True)
        (task / "status").write_text(
            f"Uid:\t{os.geteuid()}\t{os.geteuid()}\t0\t0\nState:\tS (sleeping)\n")
        (task / "fd").mkdir()
        (task / "cwd").symlink_to(self.root)
        if fd:
            (task / "fd" / "9").symlink_to(reference)
        else:
            (task / "cwd").unlink()
            (task / "cwd").symlink_to(reference)
        return task

    def test_removal_is_nonforced_preserves_branch_and_writes_receipt(self):
        native = cleanup._git
        with patch.object(cleanup, "_git", wraps=native) as calls:
            result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(attempted, 1)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git("rev-parse", "feature"), self.head)
        removals = [call.args for call in calls.call_args_list if "remove" in call.args]
        self.assertEqual(len(removals), 2)  # source plus restoration probe
        self.assertTrue(all("--force" not in args for args in removals))
        with self.store.connection() as connection:
            receipts = [json.loads(row[0]) for row in connection.execute("SELECT payload FROM events")]
        self.assertTrue(any(row.get("type") == "reconstructible-worktree-retired"
                            and row["branch_preserved"] for row in receipts))
        self.assertTrue(any(row.get("type") == "reconstructible-host-probe-verified" for row in receipts))

    def test_managed_retention_does_not_strand_a_safely_retireable_worktree(self):
        # A modern generation admission never retired: every safe guard holds.
        self.item.update(modern=True, unbound=False)
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(attempted, 1)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git("rev-parse", "feature"), self.head)

    def test_managed_takeover_keeps_every_safety_guard(self):
        self.item.update(modern=True, unbound=False)
        (self.target / "keep").write_text("untracked")
        self.assert_retained("managed-by-current-cleanup")
        (self.target / "keep").unlink()
        self.prs.return_value = [{"head": {"ref": "feature", "sha": self.head}}]
        self.assert_retained("managed-by-current-cleanup")
        self.prs.return_value = []
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assert_retained("managed-by-current-cleanup")

    def test_preview_is_read_only(self):
        self.options = CleanupOptions(self.output, apply=False, min_age=0)
        before = set(self.store.directory.iterdir())
        summary = self.store.summary()
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "eligible", result)
        self.assertEqual(attempted, 0)
        self.assertEqual(set(self.store.directory.iterdir()), before)
        self.assertEqual(self.store.summary(), summary)
        self.assertTrue(self.target.exists())

    def test_api_failure_retains_source(self):
        self.prs.side_effect = subprocess.CalledProcessError(1, ["gh", "api"])
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retained", result)
        self.assertTrue(self.target.exists())

    def test_untracked_and_ignored_files_remain(self):
        (self.target / "keep").write_text("untracked")
        self.assert_retained("nonempty-worktree-state")
        (self.target / ".gitignore").write_text("keep\n")
        self.assert_retained("nonempty-worktree-state")

    def test_dirty_tracked_file_remains(self):
        (self.target / "file").write_text("committed")
        self.git("-C", str(self.target), "add", "file")
        self.git("-C", str(self.target), "-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "-qm", "file")
        (self.target / "file").write_text("dirty")
        self.assert_retained("nonempty-worktree-state")

    def test_locked_remains(self):
        self.git("worktree", "lock", str(self.target))
        self.assert_retained("git-worktree-locked")

    def test_cwd_and_fd_remain(self):
        task = self.task(self.target)
        self.assert_retained("live-process-reference")
        (task / "cwd").unlink()
        (task / "cwd").symlink_to(self.root)
        (task / "fd" / "9").symlink_to(self.target / "file")
        self.assert_retained("live-process-reference")

    def test_real_live_process_cwd_and_fd_are_observed(self):
        (self.target / "file").write_text("keep")
        program = "import os,time; os.open('file',os.O_RDONLY); time.sleep(300)"
        process = subprocess.Popen(  # nosec B603 # fixed disposable fixture argv
            [sys.executable, "-c", program], cwd=self.target)
        try:
            # Enumerate only this real kernel task, avoiding unrelated runner tasks.
            task = Path("/proc") / str(process.pid)
            with patch.object(Path, "iterdir", autospec=True, side_effect=lambda path:
                              iter([task]) if path == Path("/proc") else original(path)):
                with self.assertRaisesRegex(ValueError, "live-process-reference"):
                    self.real_census(self.target)
        finally:
            process.terminate()
            process.wait(timeout=10)

    def test_unreadable_proc_fails_closed(self):
        task = self.task(self.root)
        original = Path.iterdir
        with patch.object(Path, "iterdir", autospec=True, side_effect=lambda path:
                          denied() if path == task / "fd" else original(path)):
            self.assert_retained("proc-observation-unavailable")

    def test_live_thread_missing_cwd_fails_closed(self):
        task = self.task(self.root)
        (task / "cwd").unlink()
        self.assert_retained("proc-observation-unavailable")

    def test_dead_leader_does_not_hide_live_thread_fd(self):
        task = self.task(self.target / "held-file", fd=True)
        leader = task.parent / "123"
        leader.mkdir()
        (leader / "status").write_text(
            f"Uid:\t{os.geteuid()}\t{os.geteuid()}\t0\t0\nState:\tZ (zombie)\n")
        self.assert_retained("live-process-reference")

    def test_head_without_remote_containment_remains(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assert_retained("head-not-on-remote")

    def test_open_pr_by_branch_or_sha_remains(self):
        for branch, head in [("feature", "0" * 40), ("another", self.head)]:
            with self.subTest(branch=branch):
                self.prs.return_value = [{"head": {"ref": branch, "sha": head}}]
                self.assert_retained("open-pull-request")

    def test_preservation_names_and_custom_patterns_remain(self):
        for name in ["preserved", "readonly", "recovery", "review", "custom"]:
            with self.subTest(name=name):
                target = self.base / ("repository-" + name)
                self.git("worktree", "move", str(self.target), str(target))
                self.target = target
                self.item["path"] = str(target)
                with patch.dict(os.environ, {"AIDEVOPS_WORKTREE_PRESERVE_PATTERNS": "custom"}):
                    self.assert_retained("preservation-name")

    def test_second_census_blocks_new_writer(self):
        calls = 0

        def census(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise ValueError("live-process-reference")

        with patch.object(inventory, "require_idle_proc", side_effect=census):
            self.assert_retained("live-process-reference")

    def test_unremoved_probe_can_retry_after_head_changes(self):
        native = cleanup.reconstructible
        calls = 0

        def changed(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise ValueError("live-process-reference")
            return native(*args)

        with patch.object(cleanup, "reconstructible", side_effect=changed):
            self.assert_retained("live-process-reference")
        self.git("-C", str(self.target), "-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "new head")
        self.head = self.git("-C", str(self.target), "rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/feature", self.head)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)

    def test_failed_first_probe_blocks_batch(self):
        with patch.object(cleanup, "verify_reconstructible", side_effect=ValueError("probe-failed")):
            result, _, _ = self.retire()
        self.assertEqual(result["reason"], "probe-failed")
        target = self.base / "repository-second"
        self.git("worktree", "add", "-q", "--detach", str(target), self.head)
        self.target = target
        self.item["path"] = str(target)
        with patch.object(cleanup, "verify_reconstructible", side_effect=ValueError("probe-failed")):
            self.assert_retained("reconstructible-probe-verification-pending")
        # A later successful re-verification recovers the checkpoint, not a bypass.
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)

    def test_existing_pass_drains_disposable_near_cap_repository(self):
        for index in range(2):
            self.git("worktree", "add", "-q", "--detach",
                     str(self.base / f"repository-extra-{index}"), self.head)
        before = len(self.git("worktree", "list", "--porcelain").split("worktree ")) - 1
        self.assertEqual(before, 4)  # 80% of a five-worktree cap
        config = self.root / "repos.json"
        config.write_text(json.dumps({"initialized_repos": [
            {"path": str(self.repo), "slug": "fixture/repository"}]}))
        report = cleanup.run(self.store, config, self.output, apply=True, min_age=3600)
        self.assertEqual(report["retired"], 3, report)
        after = len(self.git("worktree", "list", "--porcelain").split("worktree ")) - 1
        self.assertLess(after, 4)


def denied():
    raise PermissionError("fixture unreadable proc")


original = Path.iterdir
