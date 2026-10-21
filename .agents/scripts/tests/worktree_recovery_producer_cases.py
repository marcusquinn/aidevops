#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Producer cases run by the existing archive lifecycle suite and its fixture."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
from unittest.mock import patch

import worktree_recovery_producer as producer_engine


class ProducerCases:
    def producer(self, command, path, *arguments, check=True):
        script = Path(producer_engine.__file__)
        return self.run_command(sys.executable, script, command, path, *arguments, check=check)

    def test_producer_metadata_diagnostics_are_allowlisted(self):
        messages = (
            "ownership, ACLs or extended attributes require separate preservation",
            "special permissions or hard links require separate preservation",
        )
        for message in messages:
            error = subprocess.CalledProcessError(
                1, ["private-command"], output="private stdout",
                stderr="Traceback: private path and source text\nValueError: " + message + "\n")
            reason = producer_engine.failure_reason(error)
            self.assertTrue(reason.startswith("producer:unsupported-metadata;"))
            self.assertEqual(reason, producer_engine.failure_reason(ValueError(message)))
            self.assertNotIn("private", reason)
        for stderr in (None, "", "private failure", "ValueError: " + messages[0] + " private-path",
                       "ValueError: " + messages[0] + "\nother failure", messages[0].encode()):
            error = subprocess.CalledProcessError(1, ["private-command"], stderr=stderr)
            self.assertEqual(producer_engine.failure_reason(error), "producer:evidence-unavailable")
        self.assertEqual(producer_engine.failure_reason(subprocess.TimeoutExpired("private", 1)),
                         "producer:evidence-unavailable")

    def test_removal_capture_refuses_group_writable_tracked_modes(self):
        scripts = Path(producer_engine.__file__).parent
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY", None)
        tracked = self.work / "mixed.txt"
        original = tracked.read_bytes()
        registration = self.git(self.repo, "worktree", "list", "--porcelain")
        for mode in (0o664, 0o775):
            with self.subTest(mode=oct(mode)):
                tracked.chmod(mode)
                # Exercise the same capture gate that refuses native removal,
                # without depending on host-wide process/CWD visibility.
                result = self.run_command(
                    "bash", "-c", 'source "$1" && _archive_worktree_path_recoverably_under_lock '
                    '"$2" test.sh metadata-fixture "$3"', "metadata-removal",
                    scripts / "audit-worktree-removal-helper.sh", self.work, self.archives,
                    cwd=self.repo, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"producer:unsupported-metadata;", result.stderr)
                self.assertIn(b"require separate preservation; source retained", result.stderr)
                self.assertNotIn(b"producer:evidence-unavailable", result.stderr)
                self.assertNotIn(b"Traceback", result.stderr)
                self.assertNotIn(str(tracked).encode(), result.stderr)
                self.assertEqual(tracked.read_bytes(), original)
                self.assertEqual(stat.S_IMODE(tracked.stat().st_mode), mode)
                self.assertEqual(self.git(self.repo, "worktree", "list", "--porcelain"), registration)
                journals = list(self.archives.glob(".producer-transactions/*/journal.json"))
                self.assertEqual(len(journals), 1)
                record = json.loads(journals[0].read_text())
                self.assertEqual(record["phase"], "capturing")
                self.assertEqual(list(Path(record["output"]).iterdir()), [])

    def test_git_only_capture_contains_commits_and_two_patches_without_verification(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY", None)
        (self.work / "committed.txt").write_bytes(b"committed work\n")
        self.git(self.work, "add", "committed.txt")
        self.git(self.work, "commit", "-qm", "worker commit")
        head = self.git(self.work, "rev-parse", "HEAD").strip()
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        (self.work / "new-staged").write_bytes(b"new staged file\n")
        (self.work / "binary.bin").write_bytes(b"\0staged\xff")
        self.git(self.work, "add", "mixed.txt", "new-staged", "binary.bin")
        self.git(self.work, "rm", "staged-delete")
        self.git(self.work, "mv", "old-name", "new-name")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "binary.bin").write_bytes(b"\0unstaged\xfe")
        (self.work / "unstaged-delete").unlink()
        (self.work / "run.sh").chmod(0o755)
        (self.work / "untracked").write_bytes(b"unique recovery data\n")
        cache = self.work / "cache.ignored"
        cache.mkdir()
        self.git(cache, "init", "-q")
        (cache / "payload").write_bytes(b"not recovery data\n")
        self.git(self.work, "config", "diff.noprefix", "true")
        self.git(self.work, "config", "color.ui", "always")
        options = ("--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                   "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short")
        staged = self.git(self.work, "diff", "--cached", *options)
        unstaged = self.git(self.work, "diff", *options)
        result = self.producer("capture", self.work, self.archives, "test.sh", "git-only")
        archive = Path(result.stdout.decode().strip())
        manifest = json.loads((archive / "manifest.json").read_text())
        self.assertEqual(manifest["capture_policy"], "git-only")
        self.assertEqual(manifest["head_sha"].encode(), head)
        self.assertEqual((archive / "staged.patch").read_bytes(), staged)
        self.assertEqual((archive / "diff.patch").read_bytes(), unstaged)
        self.assertEqual((archive / "untracked-files.txt").read_bytes(), b"untracked\n")
        self.assertTrue((archive / "untracked.tar.gz").exists())
        self.assertFalse((archive / "git-admin.json").exists())
        self.assertIn(head + b" HEAD", self.git(self.repo, "bundle", "list-heads", str(archive / "commits.bundle")))
        record = json.loads(producer_engine.journal_for_archive(archive).read_text())
        self.assertEqual(record["phase"], "archived")
        self.assertEqual(record["source_removal_outcome"], "pending")
        rows = [json.loads(line) for line in Path(self.env["AIDEVOPS_RECOVERY_TIMING_LOG"]).read_text().splitlines()]
        commands = {row["stage"] for row in rows if row["stage"].startswith("archive-cli.")}
        self.assertEqual(commands, {"archive-cli.archive"})
        self.assertTrue(self.work.is_dir())
        self.assert_git_only_roundtrip(archive, head, options, staged, unstaged)
        (self.work / "intent-only").write_bytes(b"not staged\n")
        self.git(self.work, "add", "-N", "intent-only")
        rejected = self.producer("capture", self.work, self.archives, "test.sh", "git-only", check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b"intent-to-add", rejected.stderr)
        self.assertTrue(self.work.is_dir())

    def assert_git_only_roundtrip(self, archive, head, options, staged, unstaged):
        # This is an external regression test, never part of archive capture.
        expected_index = self.git(self.work, "ls-files", "--stage", "-z")
        expected_status = self.git(self.work, "status", "--porcelain=v1", "--untracked-files=no")
        home = self.root / "restore-home"
        targets = self.root / "restore-worktrees"
        home.mkdir()
        targets.mkdir()
        self.env.update(HOME=str(home), AIDEVOPS_WORKTREE_BASE_DIR=str(targets),
                        AIDEVOPS_REPOS_FILE=str(home / "repos.json"),
                        WORKTREE_REGISTRY_DIR=str(home / "registry"),
                        WORKTREE_REGISTRY_DB=str(home / "registry/registry.db"))
        # Only the disposable fixture is pruned: prove restore imports the saved
        # commit from its bundle instead of borrowing an already-present object.
        base = self.git(self.repo, "rev-parse", "develop").decode().strip()
        self.git(self.repo, "update-ref", "refs/heads/feature/fixture", base)
        self.git(self.repo, "reflog", "expire", "--expire=now", "--all")
        self.git(self.repo, "gc", "--prune=now")
        missing = self.run_command("git", "-C", self.repo, "cat-file", "-e", head.decode(), check=False)
        self.assertNotEqual(missing.returncode, 0)
        restored = targets / "repo-restored"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual(self.git(restored, "rev-parse", "HEAD").strip(), head)
        self.assertEqual(self.git(restored, "ls-files", "--stage", "-z"), expected_index)
        self.assertEqual(self.git(restored, "diff", "--cached", *options), staged)
        self.assertEqual(self.git(restored, "diff", *options), unstaged)
        self.assertEqual(self.git(restored, "status", "--porcelain=v1", "--untracked-files=no"), expected_status)
        for name in ("committed.txt", "mixed.txt", "binary.bin", "new-staged", "new-name", "run.sh"):
            self.assertEqual((restored / name).read_bytes(), (self.work / name).read_bytes())
        self.assertEqual((restored / "untracked").read_bytes(), b"unique recovery data\n")
        for name in ("staged-delete", "unstaged-delete", "old-name", "cache.ignored"):
            self.assertFalse((restored / name).exists())
        self.assertEqual(self.git(restored, "rev-parse", "--path-format=absolute", "--git-common-dir"),
                         self.git(self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))

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
        before = self.snapshot(self.work)
        index = self.git(self.work, "ls-files", "--stage", "-z")
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
        self.assertEqual(record["phase"], "archived")
        self.assertEqual(record["source_removal_outcome"], "removed")
        self.assertTrue((archive / ".aidevops-archive-pin").is_file())
        self.assertFalse(list(self.archives.glob("aidevops-worktree-cleanup-*")))
        self.assertFalse(list(journal.parent.glob(".restore-*")))
        retry = self.run_command("bash", scripts / "worktree-helper.sh", "remove",
                                 self.work, "--force", cwd=self.repo, check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual(list(self.archives.rglob("manifest.json")), [archive / "manifest.json"])
        self.assertIn(str(archive).encode(), self.helper("list", "--output-root", self.archives).stdout)
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual(self.git(restored, "ls-files", "--stage", "-z"), index)
        self.assertEqual(before, self.snapshot(restored))
        self.assertFalse((restored / "unique.ignored").exists())
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
        self.assertEqual(record["phase"], "archived")
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
        offline = self.root / "original-repository-unavailable"
        self.repo.rename(offline)
        try:
            self.assertNotEqual(self.producer("verify", archive, check=False).returncode, 0)
        finally:
            offline.rename(self.repo)
        self.producer("verify", archive)
        restored = self.root / "independent-restore"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual((restored / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual(self.git(restored, "show", ":mixed.txt"), b"staged\n")
        self.assertFalse((restored / "unique.ignored").exists())
        self.assertEqual((restored / "untracked").read_bytes(), b"unique untracked\n")
        self.assertFalse((restored / ".git/objects/info/alternates").exists())

    def test_producer_transaction_rejects_drift_without_duplicate(self):
        result = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture")
        archive = Path(result.stdout.decode().strip())
        (self.work / "late.txt").write_bytes(b"late data\n")
        self.assertNotEqual(self.producer("source-matches", archive, self.work, check=False).returncode, 0)
        retry = self.producer("capture", self.work, self.archives, "test.sh", "drift-fixture", check=False)
        self.assertNotEqual(retry.returncode, 0)
        self.assertIn(b"source-drift", retry.stderr)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.assertTrue((self.work / "late.txt").is_file())
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
                producer_engine, "allocated_bytes", side_effect=OSError("interrupted after capture")):
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
        self.assertEqual(json.loads(journal.read_text())["phase"], "archived")
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
