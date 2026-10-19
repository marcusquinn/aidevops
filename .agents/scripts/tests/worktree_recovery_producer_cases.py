#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Producer cases run by the existing archive lifecycle suite and its fixture."""

import json
import os
from pathlib import Path
import shutil
import sys
from unittest.mock import patch

import worktree_recovery_producer as producer_engine


class ProducerCases:
    def producer(self, command, path, *arguments, check=True):
        script = Path(producer_engine.__file__)
        return self.run_command(sys.executable, script, command, path, *arguments, check=check)

    def test_producer_transaction_round_trip_and_retry(self):
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "unique.ignored").write_bytes(b"unique ignored\n")
        (self.work / "untracked").write_bytes(b"unique untracked\n")
        result = self.producer("capture", self.work, self.archives, "test.sh", "producer-fixture")
        archive = Path(result.stdout.decode().strip())
        self.assertTrue(self.work.is_dir())
        self.assertFalse((archive / ".git").exists())
        journals = list((self.archives / ".producer-transactions").glob("*/journal.json"))
        self.assertEqual(len(journals), 1)
        journal = journals[0]
        record = json.loads(journal.read_text())
        self.assertEqual(record["phase"], "verified")
        self.assertEqual(record["source_removal_outcome"], "pending")
        self.assertFalse(list(journal.parent.glob(".restore-*")))
        self.assertFalse(list(journal.parent.glob(".cleanup-*")))
        repeat = self.producer("capture", self.work, self.archives, "test.sh", "producer-fixture")
        self.assertEqual(result.stdout, repeat.stdout)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.producer("source-matches", archive, self.work)
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        self.producer("removed", archive)
        self.assertEqual(json.loads(journal.read_text())["source_removal_outcome"], "removed")
        self.repo.rename(self.root / "original-repository-unavailable")
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual((restored / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual(self.git(restored, "show", ":mixed.txt"), b"staged\n")
        self.assertEqual((restored / "unique.ignored").read_bytes(), b"unique ignored\n")
        self.assertEqual((restored / "untracked").read_bytes(), b"unique untracked\n")
        self.assertFalse((restored / ".git/objects/info/alternates").exists())

    def test_producer_transaction_rejects_drift_without_duplicate(self):
        result = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture")
        archive = Path(result.stdout.decode().strip())
        (self.work / "late.ignored").write_bytes(b"late data\n")
        self.assertNotEqual(self.producer("source-matches", archive, self.work, check=False).returncode, 0)
        retry = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture", check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertIn(b"source-drift", retry.stderr)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.assertTrue((self.work / "late.ignored").is_file())
        self.assertNotEqual(self.producer("removed", archive, check=False).returncode, 0)
        self.producer("verify", archive)
        manifest = archive / "manifest.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        self.assertTrue(self.work.is_dir())

    def test_producer_rejects_replaced_source_inode(self):
        self.assert_replaced_identity_rejected("path")

    def test_producer_rejects_replaced_admin_inode(self):
        self.assert_replaced_identity_rejected("admin")

    def assert_replaced_identity_rejected(self, field):
        result = self.producer("capture", self.work, self.archives, "test.sh", "identity-fixture")
        archive = Path(result.stdout.decode().strip())
        record = json.loads(producer_engine.journal_for_archive(archive).read_text())
        target = Path(record["source"]["identity"][field])
        original = target.with_name(target.name + "-original")
        target.rename(original)
        shutil.copytree(original, target, symlinks=True)
        result = self.producer("source-matches", archive, self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"source-drift", result.stderr)
        self.producer("verify", archive)
        self.assertTrue(original.is_dir())
        self.assertTrue(target.is_dir())

    def test_producer_resumes_captured_archive_without_duplicate(self):
        with patch.dict(os.environ, self.env), patch.object(
                producer_engine, "prepare_restore", side_effect=OSError("interrupted before restore")):
            with self.assertRaises(OSError):
                producer_engine.prepare(self.work, self.archives, "test.sh", "interruption-fixture")
        manifests = list(self.archives.rglob("manifest.json"))
        self.assertEqual(len(manifests), 1)
        archive = manifests[0].parent
        journal = producer_engine.journal_for_archive(archive)
        self.assertEqual(json.loads(journal.read_text())["phase"], "captured")
        self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        result = self.producer("capture", self.work, self.archives, "test.sh", "interruption-fixture")
        self.assertEqual(Path(result.stdout.decode().strip()), archive)
        self.assertEqual(json.loads(journal.read_text())["phase"], "verified")
        self.assertEqual(list(self.archives.rglob("manifest.json")), manifests)
        self.assertTrue(self.work.is_dir())

    def test_producer_preserves_partial_capture_and_serializes_retry(self):
        with patch.dict(os.environ, self.env):
            current, directory, output = producer_engine.reservation(self.work, self.archives)
            with producer_engine.operation_lock(directory):
                producer_engine.reserve(current, directory, output, "test.sh", "partial-fixture")
                blocked = self.producer("capture", self.work, self.archives, "test.sh", "partial-fixture", check=False)
                self.assertNotEqual(blocked.returncode, 0)
        partial = output / "partial-artifact"
        partial.write_bytes(b"interrupted capture evidence")
        for _ in range(2):
            retry = self.producer("capture", self.work, self.archives, "test.sh", "partial-fixture", check=False)
            self.assertNotEqual(retry.returncode, 0)
            self.assertIn(b"capture-incomplete", retry.stderr)
        self.assertEqual(partial.read_bytes(), b"interrupted capture evidence")
        self.assertEqual(list(output.iterdir()), [partial])
        self.assertTrue(self.work.is_dir())

    def test_producer_preserves_new_unreachable_scratch_object(self):
        self.assert_scratch_object_preserved("finish_scratch", "restore-verified")

    def test_producer_preserves_unsealed_interrupted_scratch(self):
        self.assert_scratch_object_preserved("verify_restore", "captured")

    def assert_scratch_object_preserved(self, interruption, phase):
        with patch.dict(os.environ, self.env), patch.object(
                producer_engine, interruption, side_effect=OSError("interrupted during restoration")):
            with self.assertRaises(OSError):
                producer_engine.prepare(self.work, self.archives, "test.sh", "scratch-drift")
        archive = next(self.archives.rglob("manifest.json")).parent
        journal = producer_engine.journal_for_archive(archive)
        record = json.loads(journal.read_text())
        self.assertEqual(record["phase"], phase)
        restored = journal.parent / record["restore_slot"] / "worktree"
        object_id = self.run_command("git", "-C", restored, "hash-object", "-w", "--stdin",
                                     input_data=b"unique scratch-only object\n").stdout.decode().strip()
        object_path = restored / ".git/objects" / object_id[:2] / object_id[2:]
        result = self.producer("capture", self.work, self.archives, "test.sh", "scratch-drift", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(object_path.is_file())
        self.assertTrue(self.work.is_dir())

    def test_producer_refuses_unsafe_roots_and_source_aliases(self):
        for root in (self.work / "archives", self.repo / ".git/archives"):
            result = self.producer("capture", self.work, root, "test.sh", "unsafe-root", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"unsafe-storage-root", result.stderr)
            self.assertFalse(root.exists())
        alias = self.root / "source-alias"
        alias.symlink_to(self.work, target_is_directory=True)
        result = self.producer("capture", alias, self.archives, "test.sh", "alias", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.archives.exists())
