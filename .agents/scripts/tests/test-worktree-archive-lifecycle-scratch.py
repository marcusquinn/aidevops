#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Legacy unsealed restore-slot recovery cases using the lifecycle fixtures."""

from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
from unittest.mock import Mock, patch


class ScratchRecoveryCases:
    def legacy_scratch(self, owned=False):
        from worktree_recovery_retirement_transaction import fingerprint
        self.env["AIDEVOPS_WORKTREE_MANAGER"] = "legacy-guards"
        archive = self.archive()
        archive_before = fingerprint(archive)

        def unchanged():
            self.assertEqual(archive_before, fingerprint(archive))
            self.assertTrue(self.work.is_dir())

        self.addCleanup(unchanged)

        def interrupt(*args):
            self.helper(*args)
            (Path(args[3]).parent / ".creation.json").unlink()
            raise ValueError("creation-interrupted")

        with self.assertRaisesRegex(ValueError, "creation-interrupted"):
            self.canonical_proof(archive, interrupt)
        directory = self.root / "proof"
        record = json.loads((directory / "journal.json").read_text())
        previous = record["canonical_restore"]
        slot = directory / previous["slot"]
        target = slot / "worktree"
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection, connection:
            if not owned:
                connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(target),))
        return record, slot, target

    def resume_legacy_scratch(self, record):
        from worktree_archive_restore import RestorationProof
        from worktree_recovery_migration_state import publish
        previous = record["canonical_restore"]
        directory = self.root / "proof"
        def save(value):
            self.assertEqual(previous["state"], "cleaned")
            publish(directory / "journal.json", value)

        with patch.dict(os.environ, self.env):
            proof = RestorationProof(directory, record, self.helper, save)
            proof.check()
        self.assertNotEqual(record["canonical_restore"]["slot"], previous["slot"])
        self.assertEqual(record["canonical_restore"]["state"], "cleaned")
        self.assertFalse((directory / previous["slot"]).exists())

    def reject_legacy_scratch(self, record):
        with self.assertRaisesRegex(ValueError, "unsealed-copy-retained"):
            self.resume_legacy_scratch(record)
        self.assertEqual(record["canonical_restore"]["state"], "restoring")

    def test_recover_legacy_scratch_without_owner(self):
        record, _slot, _target = self.legacy_scratch()
        self.resume_legacy_scratch(record)

    def test_recover_legacy_scratch_already_removed(self):
        record, slot, target = self.legacy_scratch()
        self.git(self.repo, "worktree", "remove", target)
        slot.rmdir()
        self.resume_legacy_scratch(record)
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            self.assertIsNotNone(connection.execute(
                "SELECT record FROM worktree_creation_backends WHERE path = ?", (str(target),)).fetchone())

    def test_recover_legacy_scratch_rejects_stale_git_registration(self):
        record, slot, target = self.legacy_scratch()
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection, connection:
            connection.execute("DELETE FROM worktree_creation_backends WHERE path = ?", (str(target),))
        shutil.rmtree(slot)
        self.reject_legacy_scratch(record)

    def test_recover_legacy_scratch_rejects_missing_owned_slot(self):
        record, slot, target = self.legacy_scratch(owned=True)
        self.git(self.repo, "worktree", "remove", target)
        slot.rmdir()
        self.reject_legacy_scratch(record)

    def test_recover_legacy_scratch_rejects_symlinked_parent_of_missing_slot(self):
        from worktree_archive_restore import RestorationProof
        record, slot, target = self.legacy_scratch()
        shutil.rmtree(slot)
        alias = self.root / "proof-alias"
        alias.symlink_to(self.root / "proof", target_is_directory=True)
        save = Mock()
        with patch.dict(os.environ, self.env), self.assertRaisesRegex(ValueError, "slot-changed"):
            RestorationProof.recover_unsealed(alias, record["canonical_restore"], save, record,
                                              self.repo / ".git")
        save.assert_not_called()
        self.assertEqual(record["canonical_restore"]["state"], "restoring")
        self.assertIn(os.fsencode(target), self.git(self.repo, "worktree", "list", "--porcelain"))

    def test_recover_legacy_scratch_rejects_hidden_index_edits(self):
        record, _slot, target = self.legacy_scratch()
        for flag in ("assume-unchanged", "skip-worktree"):
            with self.subTest(flag=flag):
                self.git(target, "update-index", "--" + flag, "mixed.txt")
                (target / "mixed.txt").write_text("must survive\n")
                self.assertFalse(self.git(target, "status", "--porcelain=v1"))
                self.reject_legacy_scratch(record)
                self.assertEqual((target / "mixed.txt").read_text(), "must survive\n")
                self.git(target, "update-index", "--no-" + flag, "mixed.txt")
                self.git(target, "checkout", "--", "mixed.txt")

    def test_recover_legacy_scratch_rejects_dirty(self):
        record, _slot, target = self.legacy_scratch()
        (target / "mixed.txt").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertEqual((target / "mixed.txt").read_text(), "must survive\n")

    def test_recover_legacy_scratch_rejects_ignored_files(self):
        record, _slot, target = self.legacy_scratch()
        (target / "precious.ignored").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertTrue((target / "precious.ignored").is_file())

    def spotlight_marked_scratch(self):
        record, slot, target = self.legacy_scratch()
        exclude = self.repo / ".git" / "info" / "exclude"
        exclude.parent.mkdir(exist_ok=True)
        with exclude.open("a") as handle:
            handle.write("/.metadata_never_index\n")
        (target / ".metadata_never_index").touch()
        self.assertEqual(self.git(target, "status", "--porcelain=v1", "--ignored"),
                         b"!! .metadata_never_index\n")
        return record, slot, target

    def test_recover_legacy_scratch_tolerates_framework_spotlight_marker(self):
        # GH#36279: older backfills marked archive scratch; only that exact
        # empty marker is tolerated, and the slot is then reclaimed.
        record, slot, target = self.spotlight_marked_scratch()
        self.resume_legacy_scratch(record)
        self.assertFalse(target.exists())
        self.assertFalse(slot.exists())

    def test_recover_legacy_scratch_rejects_non_empty_spotlight_marker(self):
        record, _slot, target = self.spotlight_marked_scratch()
        (target / ".metadata_never_index").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertEqual((target / ".metadata_never_index").read_text(), "must survive\n")

    def test_recover_legacy_scratch_rejects_marker_with_other_ignored_files(self):
        record, _slot, target = self.spotlight_marked_scratch()
        (target / "precious.ignored").write_text("must survive\n")
        self.reject_legacy_scratch(record)
        self.assertTrue((target / "precious.ignored").is_file())

    def test_recover_legacy_scratch_rejects_unreachable_head(self):
        record, _slot, target = self.legacy_scratch()
        (target / "mixed.txt").write_text("unreferenced commit\n")
        self.git(target, "commit", "-qam", "scratch-only")
        self.reject_legacy_scratch(record)
        self.assertTrue(target.is_dir())

    def test_recover_legacy_scratch_rejects_foreign_common_dir(self):
        from worktree_archive_restore import RestorationProof
        record, _slot, target = self.legacy_scratch()
        foreign = self.root / "foreign"
        self.run_command("git", "init", "-q", foreign)
        with patch.dict(os.environ, self.env), self.assertRaisesRegex(ValueError, "wrong-base"):
            RestorationProof.recover_unsealed(self.root / "proof", record["canonical_restore"],
                                              lambda _: None, record, foreign / ".git")
        self.assertTrue(target.is_dir())
