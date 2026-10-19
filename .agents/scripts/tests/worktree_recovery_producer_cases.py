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

    def test_manual_cli_removal_and_independent_restore(self):
        scripts = Path(producer_engine.__file__).parent
        home = self.root / "home"
        home.mkdir()
        self.env.update(HOME=str(home), AIDEVOPS_DOCKER_TEARDOWN="0",
                        AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.archives),
                        AIDEVOPS_REPOS_FILE=str(home / "repos.json"),
                        WORKTREE_REGISTRY_DIR=str(home / "registry"),
                        WORKTREE_REGISTRY_DB=str(home / "registry/registry.db"),
                        AIDEVOPS_FULL_LOOP_CLEANUP_DIR=str(home / "receipts"),
                        AIDEVOPS_CLEANUP_LOG=str(home / "cleanup.log"),
                        GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_COUNT="1",
                        GIT_CONFIG_KEY_0="diff.autoRefreshIndex", GIT_CONFIG_VALUE_0="false")
        self.run_command("bash", "-c", 'source "$1" && _init_registry_db',
                         "fixture-registry", scripts / "shared-worktree-registry.sh")
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "unique.ignored").write_bytes(b"unique ignored\n")
        (self.work / "untracked").write_bytes(b"unique untracked\n")
        admin = Path(self.git(self.work, "rev-parse", "--absolute-git-dir").decode().strip())
        (admin / "SQUASH_MSG").write_bytes(b"fixture-only draft\n")
        before = self.snapshot(self.work)
        administration = {name: (admin / name).read_bytes() for name in ("HEAD", "index", "SQUASH_MSG")}
        source_bytes = producer_engine.allocated_bytes(self.work)
        result = self.run_command("bash", scripts / "worktree-helper.sh", "remove",
                                  self.work, "--force", cwd=self.repo, check=False)
        if result.returncode and b"cwd-visibility-degraded" in result.stderr:
            self.assertTrue(self.work.is_dir())
            self.assertEqual(before, self.snapshot(self.work))
            self.assertFalse(list(self.archives.rglob("manifest.json")))
            self.skipTest("host CWD visibility is incomplete; rerun in an isolated PID namespace")
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors="replace"))
        locations = [line.removeprefix("Recovery archive: ") for line in result.stdout.decode().splitlines()
                     if line.startswith("Recovery archive: ")]
        self.assertEqual(len(locations), 1, result.stdout.decode())
        archive = Path(locations[0])
        self.assertFalse(self.work.exists())
        self.assertNotIn(str(self.work).encode(), self.git(self.repo, "worktree", "list", "--porcelain"))
        journal = producer_engine.journal_for_archive(archive)
        record = json.loads(journal.read_text())
        self.assertEqual(record["phase"], "verified")
        self.assertEqual(record["source_removal_outcome"], "removed")
        self.assertTrue((archive / ".aidevops-archive-pin").is_file())
        self.assertFalse(list(self.archives.glob("aidevops-worktree-cleanup-*")))
        self.assertFalse(list(journal.parent.glob(".restore-*")))
        retry = self.run_command("bash", scripts / "worktree-helper.sh", "remove",
                                 self.work, "--force", cwd=self.repo, check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual(list(self.archives.rglob("manifest.json")), [archive / "manifest.json"])
        self.assertIn(str(archive).encode(), self.helper("list", "--output-root", self.archives).stdout)
        self.repo.rename(self.root / "original-repository-unavailable")
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        for name, data in administration.items():
            self.assertEqual((restored / ".git" / name).read_bytes(), data)
        self.assertEqual(before, self.snapshot(restored))
        self.assertEqual((restored / "unique.ignored").read_bytes(), b"unique ignored\n")
        self.assertFalse((restored / ".git/objects/info/alternates").exists())
        self.git(restored, "fsck", "--connectivity-only")
        print(json.dumps({"cli_acceptance": {
            "source_retired": True, "source_allocated_bytes": source_bytes,
            "archive_allocated_bytes": producer_engine.allocated_bytes(archive),
            "transaction_metadata_allocated_bytes": producer_engine.allocated_bytes(journal.parent),
            "installed_store_reclamation_claimed": False}}, sort_keys=True))

    def test_list_discovers_producers_without_scratch_or_legacy_entries(self):
        standalone = self.archive()
        result = self.producer("capture", self.work, self.archives, "test.sh", "list-fixture")
        archive = Path(result.stdout.decode().strip())
        manifest = (standalone / "manifest.json").read_bytes()
        for relative in (".producer-transactions/fixture/scratch/manifest.json",
                         "aidevops-worktree-cleanup-fixture/worktree/docs/manifest.json",
                         ".producer-archives/not-a-transaction/fixture__repo/1/stamp/manifest.json"):
            path = self.archives / relative
            path.parent.mkdir(parents=True)
            metadata = json.loads(manifest)
            if relative.startswith("aidevops-worktree-cleanup-"):
                metadata.update(repo="aidevops-worktree-cleanup-fixture", issue="worktree")
            path.write_text(json.dumps(metadata))
        malformed = self.archives / "fixture__repo/99/malformed/manifest.json"
        malformed.parent.mkdir(parents=True)
        malformed.write_text("[]")
        alias = self.archives / ".producer-archives" / ("a" * 64) / "fixture__repo"
        alias.parent.mkdir(parents=True)
        alias.symlink_to(standalone.parents[1], target_is_directory=True)
        rows = self.helper("list", "--output-root", self.archives).stdout.decode().splitlines()
        self.assertEqual({row.rsplit("\t", 1)[-1] for row in rows}, {str(standalone), str(archive)})
        self.assertEqual(len(rows), 2)
        filtered = self.helper("list", "--output-root", self.archives,
                               "--repo", "fixture/repo", "--issue", "1").stdout.decode().splitlines()
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0].rsplit("\t", 1)[-1], str(standalone))
        self.assertTrue((archive / ".aidevops-archive-pin").is_file())

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
