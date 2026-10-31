#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Lifecycle coverage for Git-registered scratch with no creation registry row."""

from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
from unittest.mock import patch


class UnregisteredCases:
    def unregistered_scratch(self):
        record, slot, target = self.legacy_scratch()
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            with connection:
                connection.execute("DELETE FROM worktree_creation_backends WHERE path = ?", (str(target),))
        return record, slot, target

    def test_recover_unregistered_scratch(self):
        record, _slot, target = self.unregistered_scratch()
        self.resume_legacy_scratch(record)
        self.assertNotIn(os.fsencode(target), self.git(self.repo, "worktree", "list", "--porcelain"))

    def test_remove_recovers_unregistered_scratch_and_seals_fresh_proof(self):
        import worktree_recovery_producer as producer_engine
        from worktree_lifetime_archive import __file__ as lifecycle_path
        helper = Path(lifecycle_path).with_name("audit-worktree-removal-helper.sh")
        self.env["AIDEVOPS_WORKTREE_MANAGER"] = "legacy-guards"
        archive = Path(self.producer("capture", self.work, self.archives,
                                     "test.sh", "interrupted-proof").stdout.decode().strip())
        command = producer_engine.archive_command

        def interrupt(lock, *args):
            result = command(lock, *args)
            if args[0] == "restore":
                (Path(args[3]).parent / ".creation.json").unlink()
                raise ValueError("creation-interrupted")
            return result

        with patch.dict(os.environ, self.env), patch.object(producer_engine, "archive_command", interrupt):
            with self.assertRaisesRegex(ValueError, "creation-interrupted"):
                producer_engine.check(archive)
        journal = producer_engine.journal_for_archive(archive)
        previous = json.loads(journal.read_text())["canonical_restore"]
        slot = journal.parent / previous["slot"]
        target = slot / "worktree"
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            with connection:
                connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(target),))
                connection.execute("DELETE FROM worktree_creation_backends WHERE path = ?", (str(target),))
        # Exercise the shared guarded removal entrypoint, not RestorationProof directly.
        # Allow degraded host CWD visibility only for this disposable fixture.
        script = ('source "$1" && remove_archived_worktree_path "$2" "$3" '
                  'test.sh regression "" true false')
        self.run_command("bash", "-c", script, "fixture-removal",
                         helper, self.work, archive, cwd=self.repo)
        record = json.loads(journal.read_text())
        receipt = record["canonical_restore"]
        self.assertNotEqual(receipt["slot"], previous["slot"])
        self.assertEqual(receipt["state"], "cleaned")
        self.assertEqual(receipt["registration"]["backend"], "legacy-guards")
        self.assertRegex(receipt["creation_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(record["source_removal_outcome"], "removed")
        self.assertFalse(self.work.exists())
        self.assertFalse(slot.exists())
        self.assertFalse((journal.parent / receipt["slot"]).exists())
        listed = self.git(self.repo, "worktree", "list", "--porcelain")
        self.assertNotIn(os.fsencode(target), listed)
        self.assertNotIn(os.fsencode(self.work), listed)

    def test_recover_unregistered_scratch_rejects_dirty_ignored_and_unreachable(self):
        record, _slot, target = self.unregistered_scratch()
        (target / "precious.ignored").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertTrue((target / "precious.ignored").is_file())

    def test_recover_unregistered_scratch_rejects_hidden_index_edits(self):
        record, _slot, target = self.unregistered_scratch()
        self.git(target, "update-index", "--skip-worktree", "mixed.txt")
        (target / "mixed.txt").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertEqual((target / "mixed.txt").read_text(), "must survive\n")

    def test_recover_unregistered_scratch_rejects_foreign_common_dir(self):
        from worktree_archive_restore import RestorationProof
        record, _slot, target = self.unregistered_scratch()
        foreign = self.root / "foreign"
        self.run_command("git", "init", "-q", foreign)
        with patch.dict(os.environ, self.env), self.assertRaisesRegex(ValueError, "wrong-base"):
            RestorationProof.recover_unsealed(self.root / "proof", record["canonical_restore"],
                                              lambda _: None, record, foreign / ".git")
        self.assertTrue(target.is_dir())
