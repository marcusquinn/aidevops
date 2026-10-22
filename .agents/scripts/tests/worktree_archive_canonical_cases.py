#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Canonical restoration cases using the existing archive lifecycle fixture."""

from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
from unittest.mock import patch


class CanonicalCases:
    def canonical_proof(self, archive, command=None):
        from worktree_archive_restore import RestorationProof
        from worktree_recovery_migration_state import publish
        directory = self.root / "proof"
        directory.mkdir(mode=0o700, exist_ok=True)
        manifest = json.loads((archive / "manifest.json").read_text())
        record = {"archive": str(archive), "source": {"snapshot": manifest["source_fingerprint"]},
                  "manifest_sha256": hashlib.sha256((archive / "manifest.json").read_bytes()).hexdigest()}
        with patch.dict(os.environ, self.env):
            proof = RestorationProof(directory, record, command or self.helper,
                                     lambda value: publish(directory / "journal.json", value))
        return proof, record

    def test_canonical_proof_reuses_restore_and_cleans_registration(self):
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "binary.bin").write_bytes(b"\0changed\xff")
        (self.work / "run.sh").chmod(0o755)
        (self.work / "ordinary").write_bytes(b"untracked")
        (self.work / "link").symlink_to("mixed.txt")
        archive = self.archive()
        calls = []

        def command(*args):
            calls.append(args[0])
            return self.helper(*args)

        proof, record = self.canonical_proof(archive, command)
        proof.check()
        proof.check()
        self.assertEqual(calls, ["restore"])
        receipt = record["canonical_restore"]
        self.assertEqual(receipt["state"], "cleaned")
        self.assertFalse((self.root / "proof" / receipt["slot"]).exists())
        target = str(self.root / "proof" / receipt["slot"] / "worktree")
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            self.assertIsNone(connection.execute("SELECT 1 FROM worktree_owners WHERE worktree_path = ?",
                                                (target,)).fetchone())
            self.assertIsNone(connection.execute("SELECT 1 FROM worktree_managed_lifetimes WHERE path = ?",
                                                (target,)).fetchone())
        self.assertNotIn(target.encode(), self.git(self.repo, "worktree", "list", "--porcelain"))
        # Contents, not inode/mtime or a saved verified boolean, bind the proof.
        path = archive / "diff.patch"
        path.write_bytes(path.read_bytes() + b"damage")
        with self.assertRaisesRegex(ValueError, "archive-changed"):
            proof.check()

    def test_canonical_proof_requires_real_patch_application(self):
        archive = self.archive()
        payload = archive / "staged.patch"
        payload.write_bytes(b"not a patch\n")
        manifest_path = archive / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        for item in manifest["artifacts"]:
            if item["name"] == payload.name:
                item.update(size=payload.stat().st_size, sha256=hashlib.sha256(payload.read_bytes()).hexdigest())
        manifest_path.write_text(json.dumps(manifest))
        self.helper("verify", archive)  # Integrity alone is insufficient.

        def command(*args):
            result = self.helper(*args, check=False)
            if result.returncode:
                raise ValueError("patch-application-failed")

        with self.assertRaisesRegex(ValueError, "patch-application-failed"):
            self.canonical_proof(archive, command)
        receipt = json.loads((self.root / "proof/journal.json").read_text())["canonical_restore"]
        self.assertEqual(receipt["state"], "restoring")
        self.assertTrue((self.root / "proof" / receipt["slot"]).exists())
        self.assertTrue(self.work.exists())

    def test_canonical_proof_rejects_base_mutation(self):
        proof, _ = self.canonical_proof(self.archive())
        self.git(self.repo, "hash-object", "-w", "--stdin")
        with self.assertRaisesRegex(ValueError, "base-changed"):
            proof.check()

    def test_canonical_proof_rejects_creation_owner_transfer(self):
        def transfer(*args):
            self.helper(*args)
            with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection, connection:
                connection.execute("UPDATE worktree_owners SET owner_session = 'transferred' WHERE worktree_path = ?",
                                   (str(args[3]),))

        with self.assertRaisesRegex(ValueError, "creation-generation-changed"):
            self.canonical_proof(self.archive(), transfer)
        receipt = json.loads((self.root / "proof/journal.json").read_text())["canonical_restore"]
        self.assertEqual(receipt["state"], "restoring")
        self.assertTrue((self.root / "proof" / receipt["slot"] / "worktree").exists())
        self.assertTrue(self.work.exists())

    def test_canonical_proof_rejects_restored_state_mismatch(self):
        def changed(*args):
            self.helper(*args)
            (Path(args[3]) / "mixed.txt").write_bytes(b"changed after restore\n")

        with self.assertRaisesRegex(ValueError, "state-mismatch"):
            self.canonical_proof(self.archive(), changed)
        self.assertTrue(self.work.exists())

    def test_canonical_proof_rejects_alternate_introduced_during_restore(self):
        def changed(*args):
            self.helper(*args)
            (self.repo / ".git/objects/info/alternates").write_text("")

        with self.assertRaisesRegex(ValueError, "external-object-store-added"):
            self.canonical_proof(self.archive(), changed)
        self.assertTrue(self.work.exists())

    def test_canonical_managed_old_receipt_requires_revalidation(self):
        managed = self.managed_fixture()
        archive = self.prepare_managed(managed)
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            record = managed.load(connection, str(self.work))
            record["archive_operation"].pop("canonical_restore")
            managed.save(connection, record)
            connection.commit()
        proof = Path(__file__).resolve().parents[1] / "worktree-managed-lifetime.py"
        failed = self.run_command(sys.executable, proof, "proof", self.work, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"canonical restoration receipt unavailable", failed.stderr)
        self.assertTrue(self.work.exists())
        self.assertEqual(self.prepare_managed(managed), archive)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["canonical_restore"]["state"], "cleaned")
        self.assertEqual(len(list((self.archives / ".lifecycle").iterdir())), 1)

    def test_canonical_retirement_revalidates_old_plan_without_proof(self):
        from worktree_recovery_migration_state import load, publish
        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        path = Path(migration["receipt"]).parent / "retirement.json"
        record = load(path)
        record.pop("canonical_restore")
        publish(path, record)
        result = json.loads(self.retirement("retire", bucket, "--confirm", plan["confirmation_token"]).stdout)
        self.assertTrue(result["retired"])
        self.assertEqual(load(path)["canonical_restore"]["state"], "cleaned")

    def test_canonical_cleanup_resumes_after_native_removal_and_registry_commit(self):
        managed = self.managed_fixture()
        original = Path.rmdir

        def interrupted(path):
            if path.name.startswith(".restore-"):
                raise OSError("interrupted after native/registry cleanup")
            return original(path)

        with patch.object(Path, "rmdir", interrupted), self.assertRaisesRegex(OSError, "after native"):
            self.prepare_managed(managed)
        operation = self.managed_record(managed)["archive_operation"]
        receipt = operation["canonical_restore"]
        self.assertEqual(receipt["state"], "cleanup-pending")
        slot = Path(operation["directory"]) / receipt["slot"]
        self.assertFalse((slot / "worktree").exists())
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            self.assertIsNone(connection.execute("SELECT 1 FROM worktree_owners WHERE worktree_path = ?",
                                                (str(slot / "worktree"),)).fetchone())
        self.prepare_managed(managed)
        self.assertFalse(slot.exists())
        self.assertEqual(self.managed_record(managed)["archive_operation"]["canonical_restore"]["state"], "cleaned")
        self.assertTrue(self.work.exists())
