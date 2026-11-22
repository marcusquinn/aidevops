#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused tests for approval-bound local marketing actions."""

from __future__ import annotations

import copy
import fcntl
import getpass
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable
from unittest.mock import patch

import sys

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import marketing_action_approval as records  # noqa: E402
import marketing_actions as actions  # noqa: E402

GIT = shutil.which("git")
if GIT is None:
    raise RuntimeError("git executable is unavailable")


class MarketingActionTests(unittest.TestCase):
    def setUp(self):
        temp_root = Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
        temp_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="marketing-actions-", dir=temp_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.canonical = self.root / "canonical"
        self.worktree = self.root / "worktree"
        self.receipts = self.root / "receipts"
        # The sudo ceremony writes root-owned records under the operator home;
        # tests redirect that home and trust the test user instead of root.
        home = self.root / "home"
        (home / ".aidevops").mkdir(parents=True)
        for patcher in (patch.object(records, "_home", return_value=home),
                        patch.object(records, "TRUSTED_APPROVAL_UID", os.getuid())):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.canonical.mkdir()
        self.git("init", "-b", "main", cwd=self.canonical)
        self.git("config", "user.email", "test@example.invalid", cwd=self.canonical)
        self.git("config", "user.name", "Marketing Test", cwd=self.canonical)
        (self.canonical / "page.html").write_text("<title>Old</title>\n<a href='/old'>Old</a>\n", encoding="utf-8")
        (self.canonical / "second.html").write_text('<meta name="description" content="Old">\n', encoding="utf-8")
        self.git("add", ".", cwd=self.canonical)
        self.git("commit", "-m", "fixture", cwd=self.canonical)
        self.git("worktree", "add", "-b", "feature/actions", str(self.worktree), cwd=self.canonical)
        self.input = {
            "schema": actions.INPUT_SCHEMA,
            "project_root": str(self.worktree),
            "owner": "current",
            "source_evidence": ["aidevops.marketing-decision-report/v1:test"],
            "actions": [
                {"id": "title", "kind": "title", "path": "page.html", "old": "<title>Old</title>",
                 "new": "<title>New</title>", "expected_matches": 1},
                {"id": "meta", "kind": "meta_description", "path": "second.html", "old": 'content="Old"',
                 "new": 'content="New"', "expected_matches": 1},
                {"id": "campaign", "kind": "campaign", "handoff": "account owner review"},
            ],
        }

    @staticmethod
    def git(*arguments: str, cwd: Path) -> str:
        process = subprocess.run(  # nosec B603 - test fixture invokes only local Git commands
            [GIT, *arguments], cwd=cwd, capture_output=True, text=True, check=True
        )
        return process.stdout.strip()

    def cancellation(self, nonce: str) -> Path:
        path = self.root / f"cancel-{nonce}"
        path.write_text(f"active:{nonce}\n", encoding="utf-8")
        path.chmod(0o600)
        return path

    @staticmethod
    def rollback_plan(receipt: dict) -> dict:
        return {
            "plan_digest": receipt["plan_digest"], "project_root": receipt["project_root"],
            "worktree_identity": receipt["worktree_identity"], "owner": receipt["owner"],
            "action_set": [item["action_id"] for item in receipt["files"]],
        }

    @contextmanager
    def approval(self, plan: dict, operation: str = "apply", **options):
        """Store a v2 record as the (patched) trusted approver, as the sudo ceremony would."""
        receipt: dict | None = options.get("receipt")
        stale: bool = options.get("stale", False)
        mutate: Callable[[dict], None] | None = options.get("mutate")
        now = datetime.now(timezone.utc)
        issued = now - timedelta(hours=1) if stale else now - timedelta(seconds=1)
        nonce = "approvaltest"
        record = records.build_record(
            plan, operation, actions.PLAN_SCHEMA, issued_at=issued, ttl_seconds=300, nonce=nonce,
            receipt_digest=actions.digest(receipt) if receipt is not None else None,
            cancellation_path=str(self.cancellation(nonce)),
        )
        if mutate:
            mutate(record)
        path = records.store_record(record)
        try:
            yield path
        finally:
            path.unlink(missing_ok=True)

    def test_plan_has_exact_diff_hashes_and_excluded_handoff(self):
        plan = actions.build_plan(self.input)
        self.assertEqual(plan["owner"], getpass.getuser())
        self.assertEqual(plan["action_set"], ["title", "meta"])
        self.assertIn("-<title>Old</title>", plan["actions"][0]["diff"])
        self.assertEqual(plan["actions"][2]["status"], "handoff_only")
        self.assertEqual(actions.validate_plan(copy.deepcopy(plan)), plan)

    def assert_denied_unchanged(self, plan: dict) -> None:
        with self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)
        self.assertIn("<title>Old</title>", (self.worktree / "page.html").read_text(encoding="utf-8"))

    def test_missing_stale_mismatched_and_cancelled_approval_deny(self):
        plan = actions.build_plan(self.input)
        self.assert_denied_unchanged(plan)
        for mutation in (
            lambda item: item.update(action_set=["other"]),
            lambda item: item.update(plan_digest="sha256:" + "0" * 64),
            lambda item: item.update(binding={**item["binding"], "worktree_identity": "other"}),
            lambda item: item.update(schema="aidevops.marketing-action-approval/v1"),
        ):
            with self.approval(plan, mutate=mutation):
                self.assert_denied_unchanged(plan)
        with self.approval(plan, stale=True):
            self.assert_denied_unchanged(plan)
        with self.approval(plan, operation="rollback", receipt={"wrong": "operation"}) as path:
            path.rename(records.record_path(plan["owner"], "apply", plan["plan_digest"]))
            self.assert_denied_unchanged(plan)
        with self.approval(plan):
            (self.root / "cancel-approvaltest").write_text("cancelled\n", encoding="utf-8")
            self.assert_denied_unchanged(plan)

    def test_untrusted_owner_symlinked_record_and_inherited_pipes_grant_nothing(self):
        plan = actions.build_plan(self.input)
        with self.approval(plan), patch.object(records, "TRUSTED_APPROVAL_UID", os.getuid() + 1):
            self.assert_denied_unchanged(plan)  # a user-owned record is not an operator decision
        with self.approval(plan) as path:
            moved = path.with_name("elsewhere.json")
            path.rename(moved)
            path.symlink_to(moved)
            self.assert_denied_unchanged(plan)
            moved.unlink()
        approval_read, approval_write = os.pipe()
        os.close(approval_write)
        environment = {"AIDEVOPS_MARKETING_APPROVAL_FD": str(approval_read),
                       "AIDEVOPS_MARKETING_APPROVAL_KEY_FD": str(approval_read)}
        try:
            with patch.dict(os.environ, environment):
                self.assert_denied_unchanged(plan)
        finally:
            os.close(approval_read)

    def test_mint_requires_root_sudo_user_tty_and_typed_confirmation(self):
        plan = actions.build_plan(self.input)
        plan_path = self.root / "plan.json"
        plan_path.write_bytes(actions.canonical_json(plan))
        tty = patch.object(sys.stdin, "isatty", return_value=True)
        sudo = patch.dict(os.environ, {"SUDO_USER": getpass.getuser()})
        with self.assertRaises(records.ApprovalError):
            records.mint(plan_path=str(plan_path), prompt=lambda _: "APPROVE")
        with patch.object(records.os, "geteuid", return_value=0):
            with patch.dict(os.environ, {"SUDO_USER": ""}), tty, self.assertRaises(records.ApprovalError):
                records.mint(plan_path=str(plan_path), prompt=lambda _: "APPROVE")
            with sudo, patch.object(sys.stdin, "isatty", return_value=False), self.assertRaises(records.ApprovalError):
                records.mint(plan_path=str(plan_path), prompt=lambda _: "APPROVE")
            with sudo, tty, self.assertRaises(records.ApprovalError):
                records.mint(plan_path=str(plan_path), stream=io.StringIO(), prompt=lambda _: "yes")
            self.assertFalse(records.record_path(plan["owner"], "apply", plan["plan_digest"]).exists())
            summary = io.StringIO()
            with sudo, tty:
                result = records.mint(plan_path=str(plan_path), stream=summary, prompt=lambda _: "APPROVE")
        self.assertIn("APPLY title [title] page.html", summary.getvalue())
        self.assertEqual(result["operation"], "apply")
        receipt, _ = actions.apply_plan(plan, self.receipts)
        self.assertEqual(receipt["status"], "applied")

    def test_apply_replay_changed_content_and_guarded_rollback(self):
        plan = actions.build_plan(self.input)
        with self.approval(plan):
            receipt, replayed = actions.apply_plan(plan, self.receipts)
        self.assertFalse(replayed)
        self.assertIn("<title>New</title>", (self.worktree / "page.html").read_text(encoding="utf-8"))
        with self.approval(plan):
            self.assertTrue(actions.apply_plan(plan, self.receipts)[1])
        receipt_path = actions._receipt_path(self.receipts, plan["plan_digest"])
        rollback_plan = self.rollback_plan(receipt)
        (self.worktree / "page.html").write_text("unrelated\n", encoding="utf-8")
        with self.approval(rollback_plan, "rollback", receipt=receipt), self.assertRaises(actions.ActionError):
            actions.rollback_receipt(receipt, receipt_path)
        self.assertEqual((self.worktree / "page.html").read_text(encoding="utf-8"), "unrelated\n")

    def test_rollback_restores_all_files_and_replay_is_noop(self):
        plan = actions.build_plan(self.input)
        with self.approval(plan):
            receipt, _ = actions.apply_plan(plan, self.receipts)
        receipt_path = actions._receipt_path(self.receipts, plan["plan_digest"])
        rollback_plan = self.rollback_plan(receipt)
        with self.approval(rollback_plan, "rollback", receipt=receipt):
            rolled_back, replayed = actions.rollback_receipt(receipt, receipt_path)
        self.assertFalse(replayed)
        self.assertIn("<title>Old</title>", (self.worktree / "page.html").read_text(encoding="utf-8"))
        with self.approval(rollback_plan, "rollback", receipt=rolled_back):
            self.assertTrue(actions.rollback_receipt(rolled_back, receipt_path)[1])

    def test_interrupted_checkpoint_resumes_and_competing_lock_denies(self):
        plan = actions.build_plan(self.input)
        receipt = {
            "schema": actions.RECEIPT_SCHEMA, "status": "applying", "plan_digest": plan["plan_digest"],
            "project_root": str(self.worktree), "worktree_identity": plan["worktree_identity"],
            "owner": plan["owner"], "approval_nonce": "old", "remaining_action_ids": ["title", "meta"],
            "files": [{
                "action_id": "title", "path": "page.html", "before_sha256": plan["actions"][0]["before_sha256"],
                "after_sha256": plan["actions"][0]["after_sha256"],
                "before_base64": "PHRpdGxlPk9sZDwvdGl0bGU+CjxhIGhyZWY9Jy9vbGQnPk9sZDwvYT4K",
            }],
        }
        self.receipts.mkdir(mode=0o700)
        receipt_path = actions._receipt_path(self.receipts, plan["plan_digest"])
        actions._atomic_write(receipt_path, actions.canonical_json(receipt) + b"\n")
        lock_path = Path(self.git("rev-parse", "--absolute-git-dir", cwd=self.worktree)) / "aidevops-marketing-actions.lock"
        with lock_path.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.approval(plan), self.assertRaises(actions.ActionError):
                actions.apply_plan(plan, self.receipts)
        with self.approval(plan):
            recovered, _ = actions.apply_plan(plan, self.receipts)
        self.assertEqual(recovered["status"], "applied")
        self.assertEqual(recovered["remaining_action_ids"], [])

    def test_symlink_changed_before_hash_and_default_branch_fail_closed(self):
        symlink_input = copy.deepcopy(self.input)
        (self.worktree / "link.html").symlink_to("page.html")
        symlink_input["actions"][0]["path"] = "link.html"
        with self.assertRaises((actions.ActionError, OSError)):
            actions.build_plan(symlink_input)
        plan = actions.build_plan(self.input)
        (self.worktree / "second.html").write_text("changed\n", encoding="utf-8")
        with self.approval(plan), self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)
        self.assertIn("<title>Old</title>", (self.worktree / "page.html").read_text(encoding="utf-8"))
        default_input = copy.deepcopy(self.input)
        default_input["project_root"] = str(self.canonical)
        with self.assertRaises(actions.ActionError):
            actions.build_plan(default_input)

    def test_private_receipts_reject_symlinks_and_existing_unsafe_permissions(self):
        unsafe = self.root / "unsafe-receipts"
        unsafe.mkdir(mode=0o755)
        unsafe.chmod(0o755)
        with self.assertRaises(actions.ActionError):
            actions._private_directory(unsafe)
        self.assertEqual(unsafe.stat().st_mode & 0o777, 0o755)
        real = self.root / "real-receipts"
        real.mkdir(mode=0o700)
        link = self.root / "linked-receipts"
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaises(actions.ActionError):
            actions._private_directory(link)

    def test_corrupt_completed_receipt_cannot_skip_actions(self):
        plan = actions.build_plan(self.input)
        self.receipts.mkdir(mode=0o700)
        receipt_path = actions._receipt_path(self.receipts, plan["plan_digest"])
        corrupt = {
            "schema": actions.RECEIPT_SCHEMA, "status": "applied", "plan_digest": plan["plan_digest"],
            "project_root": plan["project_root"], "worktree_identity": plan["worktree_identity"],
            "owner": plan["owner"], "approval_nonce": "forged", "files": [],
            "remaining_action_ids": [], "completed_at": "2026-01-01T00:00:00Z",
        }
        actions._atomic_write(receipt_path, actions.canonical_json(corrupt) + b"\n")
        with self.approval(plan), self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)

    def test_target_parent_symlink_swap_is_rejected(self):
        nested = self.worktree / "content"
        nested.mkdir()
        (nested / "page.html").write_text("Old\n", encoding="utf-8")
        self.git("add", "content/page.html", cwd=self.worktree)
        self.git("commit", "-m", "nested fixture", cwd=self.worktree)
        proposal = copy.deepcopy(self.input)
        proposal["actions"] = [{
            "id": "nested", "kind": "title", "path": "content/page.html",
            "old": "Old", "new": "New", "expected_matches": 1,
        }]
        plan = actions.build_plan(proposal)
        external = self.root / "external"
        external.mkdir()
        sentinel = external / "page.html"
        sentinel.write_text("external\n", encoding="utf-8")
        nested.rename(self.worktree / "content-moved")
        nested.symlink_to(external, target_is_directory=True)
        with self.approval(plan), self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "external\n")

    def test_rollback_cannot_replace_an_unrelated_private_file(self):
        plan = actions.build_plan(self.input)
        with self.approval(plan):
            receipt, _ = actions.apply_plan(plan, self.receipts)
        rollback_plan = self.rollback_plan(receipt)
        unrelated = self.root / "unrelated-private.json"
        unrelated.write_text("private sentinel\n", encoding="utf-8")
        unrelated.chmod(0o600)
        with self.approval(rollback_plan, "rollback", receipt=receipt), self.assertRaises(actions.ActionError):
            actions.rollback_receipt(receipt, unrelated)
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "private sentinel\n")


if __name__ == "__main__":
    unittest.main()
