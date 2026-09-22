#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused tests for approval-bound local marketing actions."""

from __future__ import annotations

import copy
import fcntl
import getpass
import hashlib
import hmac
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
        receipt: dict | None = options.get("receipt")
        stale: bool = options.get("stale", False)
        mutate: Callable[[dict], None] | None = options.get("mutate")
        key = b"runtime-owned-test-key-material-32-bytes"
        now = datetime.now(timezone.utc)
        issued = now - timedelta(hours=1) if stale else now - timedelta(seconds=1)
        nonce = "approval-test"
        document = {
            "schema": actions.APPROVAL_SCHEMA,
            "operation": operation,
            "plan_digest": plan["plan_digest"],
            "project_root": plan["project_root"],
            "worktree_identity": plan["worktree_identity"],
            "action_set": plan["action_set"],
            "owner": plan["owner"],
            "issued_at": issued.isoformat().replace("+00:00", "Z"),
            "expires_at": (issued + timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
            "nonce": nonce,
            "cancellation_path": str(self.cancellation(nonce)),
            "receipt_digest": actions.digest(receipt) if receipt is not None else None,
        }
        document["signature"] = hmac.new(key, actions.canonical_json(document), hashlib.sha256).hexdigest()
        if mutate:
            mutate(document)
        approval_read, approval_write = os.pipe()
        key_read, key_write = os.pipe()
        os.write(approval_write, actions.canonical_json(document))
        os.write(key_write, key)
        os.close(approval_write)
        os.close(key_write)
        environment = {
            "AIDEVOPS_MARKETING_APPROVAL_FD": str(approval_read),
            "AIDEVOPS_MARKETING_APPROVAL_KEY_FD": str(key_read),
        }
        try:
            with patch.dict(os.environ, environment):
                yield
        finally:
            os.close(approval_read)
            os.close(key_read)

    def test_plan_has_exact_diff_hashes_and_excluded_handoff(self):
        plan = actions.build_plan(self.input)
        self.assertEqual(plan["owner"], getpass.getuser())
        self.assertEqual(plan["action_set"], ["title", "meta"])
        self.assertIn("-<title>Old</title>", plan["actions"][0]["diff"])
        self.assertEqual(plan["actions"][2]["status"], "handoff_only")
        self.assertEqual(actions.validate_plan(copy.deepcopy(plan)), plan)

    def test_missing_forged_stale_mismatched_and_cancelled_approval_deny(self):
        plan = actions.build_plan(self.input)
        with self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)
        for mutation in (
            lambda item: item.update(signature="0" * 64),
            lambda item: item.update(action_set=["other"]),
        ):
            with self.approval(plan, mutate=mutation), self.assertRaises(actions.ActionError):
                actions.apply_plan(plan, self.receipts)
        with self.approval(plan, stale=True), self.assertRaises(actions.ActionError):
            actions.apply_plan(plan, self.receipts)
        with self.approval(plan) as _:
            (self.root / "cancel-approval-test").write_text("cancelled\n", encoding="utf-8")
            with self.assertRaises(actions.ActionError):
                actions.apply_plan(plan, self.receipts)

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
