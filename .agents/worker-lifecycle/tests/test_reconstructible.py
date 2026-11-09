"""Remote-recoverable retirement, exclusively using disposable repositories."""

import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from tests import test_retirement as fixtures
from worker_lifecycle import legacy_cleanup as cleanup
from worker_lifecycle import legacy_inventory as inventory
from worker_lifecycle import legacy_probe as probe
from worker_lifecycle import legacy_proc
from worker_lifecycle.admission import AdmissionRegistry
from worker_lifecycle.cleanup_plan import enrolled_only_event_id, prepare_cleanup
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
        self.real_census = legacy_proc.require_idle_proc
        census = patch.object(inventory, "require_idle_processes",
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
        with patch.object(cleanup, "_git", wraps=native) as calls, \
                patch.object(probe, "_git", calls):
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
        # Operator authorization closes the never-owned generation atomically.
        generation = self.reserve_managed()
        AdmissionRegistry(self.store).authorize_enrolled_only(
            enrolled_only_event_id(generation), generation)
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(attempted, 1)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git("rev-parse", "feature"), self.head)

    def reserve_managed(self):
        generation = str(uuid4())
        AdmissionRegistry(self.store).open_generation(str(uuid4()), generation, self.target)
        with self.store.connection() as connection:
            self.item = inventory.inventory(connection)[0]
        return generation

    def test_managed_open_empty_admission_is_retained_in_preview_and_apply(self):
        self.reserve_managed()
        for apply in (False, True):
            with self.subTest(apply=apply):
                self.options = CleanupOptions(self.output, apply=apply, min_age=0)
                self.assert_retained("managed-admission-not-closed")

    def test_managed_closed_empty_admission_needs_operator_authorization(self):
        generation = self.reserve_managed()
        AdmissionRegistry(self.store).close_generation(str(uuid4()), generation)
        self.assert_retained("managed-operator-authorization-required")

    def test_managed_detached_enrollment_does_not_prove_creation(self):
        self.git("-C", str(self.target), "checkout", "--detach", "-q")
        generation = self.reserve_managed()
        AdmissionRegistry(self.store).authorize_enrolled_only(
            enrolled_only_event_id(generation), generation)
        self.assert_retained("managed-detached-creation-unverified")

    def test_managed_detached_verified_creation_can_be_retired(self):
        self.git("worktree", "remove", str(self.target))
        fixtures.RetirementContract.create(self)
        for name in ("work.txt", ".gitignore", "cache.ignored"):
            (self.target / name).unlink()
        prepared = prepare_cleanup(self.store, self.target)
        self.assertTrue(prepared["creation_verified"])
        self.assertEqual(prepared["admission"], "closed")
        with self.store.connection() as connection:
            self.item = inventory.inventory(connection)[0]
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(attempted, 1)
        self.assertFalse(self.target.exists())

    def test_managed_takeover_closes_quiescent_admission_only_when_applying(self):
        # GH#37101 cause 2: ended runs left admission open, so takeover never retired.
        self.git("worktree", "remove", str(self.target))
        fixtures.RetirementContract.create(self)
        for name in ("work.txt", ".gitignore", "cache.ignored"):
            (self.target / name).unlink()
        with self.store.connection() as connection:
            self.item = inventory.inventory(connection)[0]
        self.options = CleanupOptions(self.output, apply=False, min_age=0)
        self.assert_retained("managed-admission-not-closed")
        with self.store.connection() as connection:
            states = {row[0] for row in connection.execute(
                "SELECT state FROM generation_admissions")}
        self.assertEqual(states, {"open"})
        self.options = CleanupOptions(self.output, apply=True, min_age=0)
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(attempted, 1)
        self.assertFalse(self.target.exists())

    def test_managed_takeover_keeps_every_safety_guard(self):
        self.item.update(modern=True, unbound=False)
        (self.target / "keep").write_text("untracked")
        self.assert_retained("nonempty-worktree-state")
        (self.target / "keep").unlink()
        self.prs.return_value = [{"head": {"ref": "feature", "sha": self.head}}]
        self.assert_retained("open-pull-request")
        self.prs.return_value = []
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assert_retained("head-not-on-remote")

    def test_automatic_modern_pass_retires_old_verified_creation_without_confirmation(self):
        self.git("worktree", "remove", str(self.target))
        fixtures.RetirementContract.create(self)
        for name in ("work.txt", ".gitignore", "cache.ignored"):
            (self.target / name).unlink()
        prepared = prepare_cleanup(self.store, self.target)
        self.assertTrue(prepared["creation_verified"])
        self.assertEqual(prepared["admission"], "closed")
        config = self.root / "repos.json"
        config.write_text(json.dumps({"initialized_repos": [
            {"path": str(self.repo), "slug": "fixture/repository"}]}))
        future = time.time() + 7200
        with patch.object(inventory.time, "time", return_value=future):
            preview = cleanup.run(self.store, config, self.output, min_age=3600)
            self.assertEqual(preview["eligible"], 1, preview)
            self.assertTrue(self.target.exists())
            report = cleanup.run(self.store, config, self.output, apply=True, min_age=3600)
        self.assertEqual(report["operator_confirmed_paths"], [])
        self.assertEqual(report["retired"], 1, report)
        self.assertFalse(self.target.exists())
        with self.store.connection() as connection:
            operation = cleanup.operation_id(self.store, str(self.target))
            receipt = cleanup.receipt(connection, operation, "retired")
        self.assertEqual(receipt["type"], "reconstructible-worktree-retired")
        self.assertTrue(receipt["branch_preserved"])

    def test_modern_age_guard_applies_in_preview_and_apply(self):
        generation = self.reserve_managed()
        AdmissionRegistry(self.store).authorize_enrolled_only(
            enrolled_only_event_id(generation), generation)
        for apply in (False, True):
            with self.subTest(apply=apply):
                self.options = CleanupOptions(self.output, apply=apply, min_age=3600)
                self.assert_retained("too-recent")

    def test_modern_preview_reports_concrete_guard_and_ownership(self):
        self.reserve_managed()
        self.options = CleanupOptions(self.output, min_age=0)
        self.task(self.target)
        result, _, attempted = self.retire()
        self.assertEqual(result["reason"], "live-process-reference", result)
        self.assertEqual(result["ownership"], "managed-by-current-cleanup")
        self.assertEqual(attempted, 0)
        self.assertTrue(self.target.exists())

    def test_absent_modern_without_runs_is_not_a_takeover_failure(self):
        self.reserve_managed()
        self.git("worktree", "remove", str(self.target))
        result, eligible, attempted = self.retire()
        self.assertEqual(result["status"], "already-absent", result)
        self.assertEqual((eligible, attempted), (0, 0))

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

    def second_target(self):
        """Switch the fixture to a second remotely reconstructible worktree."""
        target = self.base / "repository-second"
        self.git("worktree", "add", "-q", "-b", "second", str(target))
        self.git("update-ref", "refs/remotes/origin/second", self.head)
        self.target = target
        self.item = dict(self.item, path=str(target))

    def test_takeover_precheck_and_plan_share_one_lookup_removal_refreshes(self):
        """GH#37181: one memoised lookup per slug per pass; removal stays fresh."""
        generation = self.reserve_managed()
        AdmissionRegistry(self.store).authorize_enrolled_only(
            enrolled_only_event_id(generation), generation)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(self.prs.call_count, 2)  # precheck+plan, pre-removal refresh
        self.item = dict(self.item, modern=False, generations=set(), runs={}, unbound=True)
        self.second_target()
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual(self.prs.call_count, 3)  # only the second removal's refresh

    def test_deferred_lookup_is_concrete_and_not_retried_in_pass(self):
        """A `gh` governor deferral (exit 75) holds every item without more calls."""
        self.prs.side_effect = subprocess.CalledProcessError(75, ["gh", "api"])
        self.assert_retained("pull-request-state-unavailable")
        self.second_target()
        self.assert_retained("pull-request-state-unavailable")
        self.assertEqual(self.prs.call_count, 1)
        # A new pass looks up again rather than inheriting the failure.
        self.prs.side_effect = None
        self.options = CleanupOptions(self.output, apply=True, min_age=0)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)

    def test_untracked_files_remain(self):
        (self.target / "keep").write_text("untracked")
        self.assert_retained("nonempty-worktree-state")

    def test_ignored_files_do_not_retain(self):
        (Path(self.common) / "info").mkdir(exist_ok=True)
        (Path(self.common) / "info" / "exclude").write_text("cache/\n")
        (self.target / "cache").mkdir()
        (self.target / "cache" / "artefact").write_text("ignored")
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertFalse(self.target.exists())

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

    @unittest.skipUnless(sys.platform == "linux", "Linux /proc process observation")
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

    def test_census_uses_native_platform_observer(self):
        """A Linux-only census retained every macOS candidate as unobservable."""
        with patch.object(inventory, "require_idle_processes",
                          legacy_proc.require_idle_processes), \
                patch.object(legacy_proc.platform, "system", return_value="Darwin"), \
                patch.object(legacy_proc, "require_idle_macos",
                             side_effect=ValueError("live-process-reference")) as observer:
            self.assert_retained("live-process-reference")
        observer.assert_called_with(self.target)

    @unittest.skipUnless(sys.platform == "darwin", "macOS lsof process observation")
    def test_real_macos_live_process_cwd_is_observed(self):
        program = "import time; time.sleep(300)"
        process = subprocess.Popen(  # nosec B603 # fixed disposable fixture argv
            [sys.executable, "-c", program], cwd=self.target)
        try:
            with self.assertRaisesRegex(ValueError, "live-process-reference"):
                legacy_proc.require_idle_processes(self.target)
        finally:
            process.terminate()
            process.wait(timeout=10)
        legacy_proc.require_idle_processes(self.target)

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
                self.prs.return_value = [{"head": {
                    "ref": branch, "sha": head,
                    "repo": {"full_name": "fixture/repository"},
                }}]
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

        with patch.object(inventory, "require_idle_processes", side_effect=census):
            self.assert_retained("live-process-reference")

    def test_github_lookups_do_not_block_unrelated_admission(self):
        """GH#36921: both open-PR lookups run without the registry writer."""
        other = self.root / "admission-target"
        other.mkdir()
        generation = str(uuid4())
        admissions = AdmissionRegistry(self.store)
        admissions.open_generation(str(uuid4()), generation, other)
        identity = self.adapter.capture(os.getpid())
        admitted = []

        def lookup(slug):
            """A second real SQLite connection admits while GitHub is queried."""
            admitted.append(admissions.admit(str(uuid4()), identity, generation, str(other)))
            return []

        self.prs.side_effect = lookup
        result, _, attempted = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertEqual((attempted, admitted), (1, [True, True]))
        self.assertFalse(self.target.exists())

    def test_registration_during_final_lookup_blocks_removal(self):
        """Every registry check reruns under the reacquired writer before removal."""
        generation = str(uuid4())
        identity = self.adapter.capture(os.getpid())

        def lookup(slug):
            """Admit a live owner for the source during the refresh lookup."""
            if self.prs.call_count == 2:
                admissions = AdmissionRegistry(self.store)
                admissions.open_generation(str(uuid4()), generation, self.target)
                self.assertTrue(admissions.admit(str(uuid4()), identity, generation))
            return []

        self.prs.side_effect = lookup
        self.assert_retained("managed-or-foreign-worktree")
        with self.store.connection() as connection:
            row = connection.execute("SELECT state FROM generation_admissions "
                                     "WHERE generation_id=?", (generation,)).fetchone()
        self.assertEqual(row["state"], "open")

    def test_writer_reacquisition_failure_after_lookup_retains_source(self):
        """A writer busy after the lookup aborts before removal; a later pass retires."""
        blocker = self.store._connect()
        self.addCleanup(blocker.close)

        def lookup(slug):
            if self.prs.call_count == 2:
                blocker.execute("BEGIN IMMEDIATE")
            return []

        self.prs.side_effect = lookup
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retained", result)
        self.assertEqual(result.get("category"), "contention", result)
        self.assertTrue(self.target.exists())
        blocker.rollback()
        self.prs.side_effect = None
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)
        self.assertFalse(self.target.exists())

    def test_unremoved_probe_can_retry_after_head_changes(self):
        native = cleanup.reconstructible
        calls = 0

        def changed(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise ValueError("live-process-reference")
            return native(*args, **kwargs)

        with patch.object(cleanup, "reconstructible", side_effect=changed):
            self.assert_retained("live-process-reference")
        self.git("-C", str(self.target), "-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "new head")
        self.head = self.git("-C", str(self.target), "rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/feature", self.head)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)

    def test_interrupted_probe_removal_is_not_reported_already_absent(self):
        with patch.object(cleanup, "verify_reconstructible", side_effect=ValueError("probe-failed")):
            self.retire()
        self.assertFalse(self.target.exists())
        self.options = CleanupOptions(self.output, apply=False, min_age=0)
        result, _, _ = self.retire()
        self.assertEqual(result["reason"], "reconstructible-probe-verification-pending", result)
        self.options = CleanupOptions(self.output, apply=True, min_age=0)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "already-absent", result)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "already-retired", result)

    def test_recovery_cancels_restored_source_without_null_plan(self):
        native = cleanup.reconstructible
        with patch.object(cleanup, "reconstructible", side_effect=[
                native(self.item, repositories=self.repositories, adapter=self.adapter,
                       open_prs=lambda slug: []), ValueError("live-process-reference")]):
            self.assert_retained("live-process-reference")
        host = probe.host_probe(self.store)
        # Simulate the source returning between the absence check and locked recovery.
        cleanup.recover_interrupted_probe(self.store, self.item, True)
        with self.store.connection() as connection:
            self.assertIsNone(probe.latest_probe_plan(connection, host))
            plans = [json.loads(row[0]) for row in connection.execute(
                "SELECT payload FROM events WHERE json_extract(payload,'$.type')=?",
                ("reconstructible-host-probe-plan",))]
        self.assertEqual(len(plans), 1)
        self.assertIsInstance(plans[0]["plan"], dict)
        result, _, _ = self.retire()
        self.assertEqual(result["status"], "retired", result)

    def test_legacy_null_probe_plan_does_not_block_new_probe(self):
        host, attempt = probe.host_probe(self.store), str(uuid4())
        with self.store.connection(write=True) as connection:
            probe.checkpoint(self.store, connection, attempt, "plan",
                             {"type": "reconstructible-host-probe-plan", "host": host,
                              "attempt": attempt, "plan": None})
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
