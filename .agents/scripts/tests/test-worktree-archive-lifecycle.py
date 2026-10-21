#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the real compact archive CLI in disposable local Git repositories."""

import datetime
from contextlib import closing
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "worktree-archive-helper.sh"
sys.path.insert(0, str(HELPER.parent))

import worktree_lifetime_archive as lifecycle
import worktree_lifecycle_status as lifecycle_status
import worktree_recovery_legacy_report as legacy_report
from worktree_archive_administration import administration_files
from worktree_recovery_producer_cases import ProducerCases


class ArchiveAdministration(unittest.TestCase):
    def test_legacy_branches_requires_empty_independent_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            admin = Path(temporary)
            branches = admin / "branches"
            branches.mkdir()
            self.assertEqual(administration_files(admin, admin, False), {})
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, True)
            child = branches / "origin"
            child.write_text("legacy remote\n")
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            child.unlink()
            child.mkdir()
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            child.rmdir()
            branches.rmdir()
            branches.write_text("not a directory\n")
            with self.assertRaisesRegex(ValueError, "^git_admin:unknown_entry:branches$"):
                administration_files(admin, admin, False)
            branches.unlink()
            branches.symlink_to(admin, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "^git_admin:symlink:branches$"):
                administration_files(admin, admin, False)


class LegacyRecoveryReport(unittest.TestCase):
    def test_name_contract_uses_pulse_generator_and_worktree_slug(self):
        producer = (HELPER.parent / "pulse-dispatch-worker-launch.sh").read_text()
        assignment = next(line.strip() for line in producer.splitlines()
                          if line.strip().startswith('_branch="feature/auto-'))
        command = 'issue_number=123; ' + assignment + '; source "$1"; aidevops_branch_slug "$_branch"'
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        result = subprocess.run(  # nosec B603 -- local trusted generator assignment and path helper
            [str(Path(bash).resolve()), "-c", command, "name-contract", str(HELPER.parent / "worktree-paths.sh")],
            capture_output=True, text=True, check=True, timeout=10)
        source = "/fixture/repo-" + result.stdout.strip()
        self.assertEqual(legacy_report.legacy_origin(source, "worktree-helper.sh", "recoverable-cleanup"), "pulse")

    def test_name_contract_rejects_lookalikes_and_profile_sources(self):
        valid = "/fixture/repo-feature-auto-20260101-120000-gh123"
        for source in (valid + "-manual", valid + "/child", valid.replace("-gh123", ""),
                       valid.replace("20260101", "20260231"), valid.replace("gh123", "gh-123"),
                       valid.replace("-feature-auto-", "-fix-auto-"), "relative" + valid):
            with self.subTest(source=source):
                self.assertEqual(legacy_report.legacy_origin(source, "worktree-helper.sh", "recoverable-cleanup"), "unknown")
        self.assertEqual(legacy_report.legacy_origin(valid, "profile-readme-helper.sh", "anything"), "profile")
        self.assertEqual(legacy_report.legacy_origin(valid, "manual.sh", "recoverable-cleanup"), "unknown")

    def test_legacy_policy_boundaries(self):
        week = legacy_report.RETENTION_SECONDS
        cases = [("pulse", week - 1, False, "within-retention"),
                 ("pulse", week, False, "eligible-legacy-pulse"),
                 ("pulse", None, False, "missing-timestamp"),
                 ("pulse", -1, False, "missing-timestamp"),
                 ("manual", week * 2, False, "manual-origin"),
                 ("profile", week * 2, False, "non-pulse-profile"),
                 ("unknown", week * 2, False, "unknown-origin"),
                 ("pulse", week * 2, True, "lifecycle-path")]
        for origin, age, managed, expected in cases:
            with self.subTest(origin=origin, age=age, managed=managed):
                self.assertEqual(legacy_report.legacy_decision(origin, age, managed), expected)

    def test_legacy_report_never_promotes_dispatch_path_to_origin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bucket = root / "aidevops-worktree-cleanup-fixture"
            metadata = bucket / ".aidevops-worktree-recovery"
            metadata.mkdir(parents=True)
            values = {"format": "aidevops-worktree-recovery-v2",
                      "archive-complete": "aidevops-worktree-recovery-v2",
                      "source-removal-outcome": "removed", "source-real": "/fixture/source",
                      "source-inode": "1:2", "producer": "worktree-helper.sh",
                      "producer-context": "recoverable-cleanup", "created-at": "2020-01-01T00:00:00Z"}
            for name, value in values.items():
                (metadata / name).write_text(value + "\n")
            ledger = root / "ledger.jsonl"
            ledger.write_text(json.dumps({"worktree_path": "/fixture/source"}) + "\n")
            registry = root / "registry.db"
            with closing(sqlite3.connect(registry)) as db:
                db.execute("CREATE TABLE worktree_managed_lifetimes(path TEXT, record TEXT)")
            result = legacy_report.report(root, registry, ledger)
            self.assertEqual(result["reasons"], {"unknown-origin": 1})
            self.assertEqual(result["ages"], {"at-least-7-days": 1})
            self.assertEqual(result["dispatch_path_matches_not_origin_proof"], 1)
            self.assertEqual(result["eligible_legacy_pulse"], 0)
            self.assertFalse(result["deletion_authorized"])
            self.assertNotIn("entries", result)
            entry = legacy_report.report(root, registry, ledger, details=True)["entries"][0]
            self.assertEqual(entry["bucket"], str(bucket))
            self.assertEqual(entry["source_path"], "/fixture/source")
            self.assertEqual(entry["source_inode"], "1:2")
            (metadata / "source-real").write_text("/fixture/repo-feature-auto-20191231-120000-gh123\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["eligible_legacy_pulse"], 1)
            (metadata / "source-real").write_text("/fixture/source\n")
            record = {"schema": 1, "manager": "pulse", "state": "sealed",
                      "identity": {"path": "/fixture/source", "source_inode": "1:2"}}
            with closing(sqlite3.connect(registry)) as db:
                db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)",
                           ("/fixture/source", json.dumps(record)))
                db.commit()
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"lifecycle-path": 1})
            (metadata / "source-inode").write_text("1:3\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"lifecycle-path": 1})
            with closing(sqlite3.connect(registry)) as db:
                db.execute("DELETE FROM worktree_managed_lifetimes")
                db.commit()
            (metadata / "producer").write_text("profile-readme-helper.sh\n")
            (metadata / "producer-context").write_text("recovery_path=profile-publication-archive profile_scratch=true\n")
            self.assertEqual(legacy_report.report(root, registry, ledger)["reasons"], {"non-pulse-profile": 1})

    def test_legacy_report_bounded_metadata_and_dates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "metadata"
            path.write_bytes(b"x" * 8193)
            with self.assertRaises(ValueError):
                legacy_report.read_small(path)
            link = root / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                legacy_report.read_small(link)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            with self.assertRaises(ValueError):
                legacy_report.read_small(fifo)
            self.assertIsNone(legacy_report.age_seconds("not-a-date", 100))
            self.assertIsNone(legacy_report.age_seconds("2100-01-01T00:00:00Z", 100))
            self.assertEqual(legacy_report.registry_records(root / "missing.db")[1], "unavailable")
            self.assertFalse((root / "missing.db").exists())


class ArchiveLifecycle(ProducerCases, unittest.TestCase):
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o022))
        self.temp = tempfile.TemporaryDirectory(prefix="archive-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
                        AIDEVOPS_RECOVERY_TIMING_LOG=str(self.root / "timing.jsonl"),
                        AIDEVOPS_WORKTREE_RECOVERY_POLICY="git-only",
                        AIDEVOPS_WORKTREE_BASE_DIR=str(self.root),
                        HOME=str(self.root),
                        WORKTREE_REGISTRY_DIR=str(self.root / "registry"),
                        WORKTREE_REGISTRY_DB=str(self.root / "registry/worktree-registry.db"),
                        GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_EMAIL="fixture@example.invalid", LC_ALL="C")
        self.repo = self.root / "repo"
        self.work = self.root / "work"
        self.archives = self.root / "archives"
        self.run_command("git", "init", "-q", "--initial-branch=develop", self.repo)
        for name, data in {
            "mixed.txt": b"base\n", "binary.bin": bytes(range(256)),
            "staged-delete": b"delete\n", "unstaged-delete": b"delete\n",
            "old-name": b"rename\n", "run.sh": b"#!/bin/sh\nexit 0\n",
            ".gitignore": b"*.ignored\n",
        }.items():
            (self.repo / name).write_bytes(data)
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-qm", "base")
        self.git(self.repo, "worktree", "add", "-qb", "feature/fixture", self.work)
        self.issue = 0

    def run_command(self, *args, check=True, input_data=None, cwd=None):
        result = subprocess.run(  # nosec B603 -- fixture-owned Git/Bash argv, no shell expansion
            [str(arg) for arg in args], env=self.env,
            capture_output=True, timeout=60, check=False, input=input_data, cwd=cwd)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def git(self, repo, *args):
        return self.run_command("git", "-C", repo, *args).stdout

    def helper(self, *args, check=True):
        return self.run_command("bash", HELPER, *args, check=check)

    def archive(self, *extra):
        self.issue += 1
        return Path(self.helper("archive", self.work, "--repo", "fixture/repo",
                                "--issue", self.issue, "--reason", "failed-worker",
                                "--base-branch", "develop", "--output-root",
                                self.archives, *extra).stdout.decode().strip())

    def auto_merge_path(self):
        return Path(os.fsdecode(self.git(self.work, "rev-parse", "--absolute-git-dir")).strip()) / "AUTO_MERGE"

    def test_auto_merge_conflict_round_trip_without_source_objects(self):
        self.git(self.repo, "checkout", "-qb", "other")
        (self.repo / "mixed.txt").write_bytes(b"other side\n")
        self.git(self.repo, "commit", "-qam", "other")
        (self.work / "mixed.txt").write_bytes(b"our side\n")
        self.git(self.work, "commit", "-qam", "ours")
        result = self.run_command("git", "-C", self.work, "merge", "other", check=False)
        self.assertNotEqual(result.returncode, 0)
        oid = self.auto_merge_path().read_bytes()
        # Active conflict is still refused, with no source removal.
        failed = self.helper("archive", self.work, "--repo", "fixture/repo", "--issue", "99",
                             "--reason", "failed-worker", "--base-branch", "develop",
                             "--output-root", self.archives, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue(self.work.exists())
        # Resolve and commit normally, then retain the genuine merge tree as a
        # standalone diagnostic reference (not a promise of merge continuation).
        (self.work / "mixed.txt").write_bytes(b"resolved\n")
        self.git(self.work, "add", "mixed.txt")
        self.git(self.work, "commit", "-qm", "resolved")
        self.auto_merge_path().write_bytes(oid)
        expected = self.git(self.work, "diff", "--binary", "AUTO_MERGE")
        source_bytes = sum((self.work / os.fsdecode(name)).stat().st_size for name in
                           self.git(self.work, 'ls-files', '-z').split(b'\0') if name)
        self.auto_merge_path().unlink()
        baseline_archive = self.archive()
        baseline_bytes = sum(p.stat().st_size for p in baseline_archive.iterdir() if p.is_file())
        self.auto_merge_path().write_bytes(oid)
        objects = self.repo / '.git/objects'
        objects_before = sum(p.stat().st_size for p in objects.rglob('*') if p.is_file())
        archive = self.archive()
        objects_after = sum(p.stat().st_size for p in objects.rglob('*') if p.is_file())
        self.assertEqual(objects_before, objects_after)
        archive_bytes = sum(p.stat().st_size for p in archive.iterdir() if p.is_file())
        self.assertTrue((archive / "auto-merge-v1.json").is_file())
        self.assertFalse((archive / "git-admin.json").exists())
        self.helper("verify", archive)
        # Keep only the recorded durable base; remove original repository and
        # worktree, including every disposable object and reflog.
        base = self.root / "retained-base.git"
        self.run_command("git", "init", "--bare", "-q", base)
        manifest = json.loads((archive / "manifest.json").read_text())
        self.git(base, "fetch", "-q", self.repo, manifest["base_sha"] + ":refs/heads/base")
        before = sum(p.stat().st_size for p in base.rglob("*") if p.is_file())
        shutil.rmtree(self.work)
        shutil.rmtree(self.repo)
        self.git(base, "gc", "--prune=now")
        manifest["source_git_common_dir"] = str(base)
        (archive / "manifest.json").write_text(json.dumps(manifest))
        target = self.root / "independent-restore"
        self.helper("restore", archive, "--target", target, "--verification-copy")
        self.assertEqual(self.git(target, "rev-parse", "AUTO_MERGE"), oid)
        self.assertEqual(self.git(target, "diff", "--binary", "AUTO_MERGE"), expected)
        self.git(target, "gc", "--prune=now")
        self.assertEqual(self.git(target, "diff", "--binary", "AUTO_MERGE"), expected)
        self.assertEqual((target / "mixed.txt").read_bytes(), b"resolved\n")
        print("AUTO_MERGE text storage:", json.dumps({
            "archive_bytes": archive_bytes, "without_auto_merge_bytes": baseline_bytes,
            "added_archive_bytes": archive_bytes - baseline_bytes,
            "new_base_object_bytes": objects_after - objects_before, "base_bytes_before_gc": before,
            "source_working_bytes": source_bytes}))

    def test_auto_merge_binary_closure_shared_base_and_corruption(self):
        content = b''.join(hashlib.sha256(str(i).encode()).digest() for i in range(32768))
        blob = self.run_command('git', '-C', self.work, 'hash-object', '-w', '--stdin',
                                input_data=content).stdout.strip()
        nested = self.run_command('git', '-C', self.work, 'mktree',
                                  input_data=b'100644 blob ' + blob + b'\tpayload.bin\n').stdout.strip()
        base_tree = self.git(self.work, 'rev-parse', 'HEAD^{tree}').strip()
        tree = self.run_command('git', '-C', self.work, 'mktree', input_data=(
            b'040000 tree ' + nested + b'\tnested\n040000 tree ' + base_tree + b'\tshared-base\n')).stdout
        path = self.auto_merge_path()
        path.write_bytes(tree)
        (self.work / 'binary.bin').write_bytes(content)
        self.git(self.work, 'add', 'binary.bin')
        (self.work / 'binary.bin').write_bytes(content + b'unstaged')
        source_bytes = sum((self.work / os.fsdecode(name)).stat().st_size for name in
                           self.git(self.work, 'ls-files', '-z').split(b'\0') if name)
        expected = self.git(self.work, 'diff', '--binary', 'AUTO_MERGE')
        objects = self.repo / '.git/objects'
        before = sum(p.stat().st_size for p in objects.rglob('*') if p.is_file())
        path.unlink()
        baseline_archive = self.archive()
        baseline_bytes = sum(p.stat().st_size for p in baseline_archive.iterdir() if p.is_file())
        path.write_bytes(tree)
        first = self.archive()
        archive = self.archive()
        after = sum(p.stat().st_size for p in objects.rglob('*') if p.is_file())
        self.assertEqual(before, after)  # Capture is read-only on the shared base.
        # Removing one independent archive cannot affect the other's closure.
        shutil.rmtree(first)
        path.unlink()
        self.assertNotEqual(self.helper('source-matches', archive, self.work, check=False).returncode, 0)
        self.git(self.repo, 'worktree', 'remove', '--force', self.work)
        self.git(self.repo, 'gc', '--prune=now')
        missing = self.run_command('git', '-C', self.repo, 'cat-file', '-e', tree.strip(), check=False)
        self.assertNotEqual(missing.returncode, 0)
        target = self.root / 'binary-restore'
        self.helper('restore', archive, '--target', target)
        self.assertEqual(self.git(target, 'rev-parse', 'AUTO_MERGE'), tree)
        self.assertEqual(self.git(target, 'show', 'AUTO_MERGE:nested/payload.bin'), content)
        self.assertEqual(self.git(target, 'diff', '--binary', 'AUTO_MERGE'), expected)
        self.assertEqual((target / 'binary.bin').read_bytes(), content + b'unstaged')
        self.assertEqual(self.git(target, 'show', ':binary.bin'), content)
        self.git(self.repo, 'gc', '--prune=now')
        self.helper('verify', archive)
        manifest = json.loads((archive / 'manifest.json').read_text())
        print('AUTO_MERGE binary storage:', json.dumps({
            'archive_bytes': sum(p.stat().st_size for p in archive.iterdir() if p.is_file()),
            'without_auto_merge_bytes': baseline_bytes,
            'added_archive_bytes': sum(p.stat().st_size for p in archive.iterdir() if p.is_file()) - baseline_bytes,
            'new_base_object_bytes': after - before, 'source_working_bytes': source_bytes,
            'bundle_bytes': (archive / 'commits.bundle').stat().st_size}))
        # Integrity checks catch corruption; even a recomputed checksum cannot
        # make an unsupported metadata version or a missing object acceptable.
        metadata = archive / 'auto-merge-v1.json'
        metadata.write_text(json.dumps({'schema': 2, 'tree': tree.decode().strip()}))
        self.assertNotEqual(self.helper('verify', archive, check=False).returncode, 0)
        for artifact in manifest['artifacts']:
            if artifact['name'] == metadata.name:
                artifact.update(size=metadata.stat().st_size, sha256=hashlib.sha256(metadata.read_bytes()).hexdigest())
        (archive / 'manifest.json').write_text(json.dumps(manifest))
        self.assertNotEqual(self.helper('verify', archive, check=False).returncode, 0)

    def test_auto_merge_already_in_base_needs_no_bundle(self):
        tree = self.git(self.work, 'rev-parse', 'HEAD^{tree}')
        self.auto_merge_path().write_bytes(tree)
        archive = self.archive()
        self.assertFalse((archive / 'commits.bundle').exists())
        self.helper('verify', archive)
        target = self.root / 'covered-restore'
        self.helper('restore', archive, '--target', target, '--verification-copy')
        self.assertEqual(self.git(target, 'rev-parse', 'AUTO_MERGE'), tree)

    def test_auto_merge_missing_closure_retains_source(self):
        tree = self.run_command('git', '-C', self.work, 'mktree', '--missing',
                                input_data=b'100644 blob ' + b'1' * 40 + b'\tmissing\n').stdout
        self.auto_merge_path().write_bytes(tree)
        result = self.helper('archive', self.work, '--repo', 'fixture/repo', '--issue', '99',
                             '--reason', 'failed-worker', '--base-branch', 'develop',
                             '--output-root', self.archives, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auto_merge_path().read_bytes(), tree)

    def test_auto_merge_invalid_sources_are_retained(self):
        path = self.auto_merge_path()
        head = self.git(self.work, "rev-parse", "HEAD")
        for content in (b"not an oid\n", b"0" * 40 + b"\n", head):
            path.write_bytes(content)
            with self.subTest(content=content):
                result = self.helper("archive", self.work, "--repo", "fixture/repo", "--issue", "99",
                                     "--reason", "failed-worker", "--base-branch", "develop",
                                     "--output-root", self.archives, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_bytes(), content)
        path.unlink()
        path.symlink_to(self.work / "mixed.txt")
        result = self.helper("archive", self.work, "--repo", "fixture/repo", "--issue", "99",
                             "--reason", "failed-worker", "--base-branch", "develop",
                             "--output-root", self.archives, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.is_symlink())

    def test_auto_merge_capture_rejects_late_tracked_and_tree_writes(self):
        tree = self.git(self.work, 'rev-parse', 'HEAD^{tree}')
        empty = self.run_command('git', '-C', self.work, 'mktree', input_data=b'').stdout
        for mutate in ('printf late > "$worktree/mixed.txt"',
                       'printf "%s\\n" "$late_tree" > "$late_path"'):
            self.auto_merge_path().write_bytes(tree)
            (self.work / 'mixed.txt').write_bytes(b'base\n')
            # Override only the final payload step to inject a deterministic late
            # write, while exercising real capture and source comparison.
            script = ('late_path="$4"; late_tree="$5"; source "$1" help >/dev/null; '
                      'capture_untracked() { local worktree="$1"; local archive="$2"; '
                      ': > "$archive/untracked-files.txt"; ' + mutate + '; return 0; }; '
                      'archive_worktree "$2" --repo fixture/repo --issue 99 '
                      '--reason failed-worker --base-branch develop --output-root "$3"')
            result = self.run_command('bash', '-c', script, 'capture-race', HELPER, self.work,
                                      self.archives, self.auto_merge_path(), empty.decode().strip(), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'worktree changed during archive capture', result.stderr)
            self.assertTrue(self.work.exists())

    def test_auto_merge_verified_legacy_retirement(self):
        tree = self.run_command('git', '-C', self.work, 'mktree', input_data=b'').stdout
        self.auto_merge_path().write_bytes(tree)
        bucket = self.legacy_pulse_bucket()
        migration = json.loads(self.migrate_bucket(bucket).stdout)
        plan = json.loads(self.retirement('retire-plan', bucket).stdout)
        retired = json.loads(self.retirement('retire', bucket, '--confirm', plan['confirmation_token']).stdout)
        self.assertTrue(retired['retired'])
        self.assertFalse(bucket.exists())
        target = self.root / 'retired-auto-merge-restore'
        self.helper('restore', migration['archive'], '--target', target, '--verification-copy')
        self.assertEqual(self.git(target, 'rev-parse', 'AUTO_MERGE'), tree)

    def legacy_bucket(self):
        home = self.root / "home"
        home.mkdir()
        recovery = self.root / "recovery"
        self.env.update(HOME=str(home), WORKTREE_REGISTRY_DIR=str(self.root / "registry"),
                        WORKTREE_REGISTRY_DB=str(self.root / "registry/worktree-registry.db"),
                        AIDEVOPS_WORKTREE_TRASH_ROOT=str(recovery),
                        AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.archives),
                        AIDEVOPS_CLEANUP_LOG=str(self.root / "cleanup.log"))
        command = ('source "$1"; source "$3"; _init_registry_db || exit 1; '
                   'create_legacy_worktree_recovery_fixture "$2" test.sh migration-test || exit 1; '
                   'printf "%s\\n" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"')
        result = self.run_command("bash", "-c", command, "migration-fixture",
                                  HELPER.parent / "worktree-recovery-lifecycle-helper.sh", self.work,
                                  HELPER.parent / "tests/legacy-worktree-recovery-fixture.sh")
        return Path(result.stdout.decode().splitlines()[-1]).parent

    def migrate_bucket(self, bucket, *extra, check=True):
        result = self.run_command("bash", HELPER.parent / "worktree-recovery-lifecycle-helper.sh",
                                  "migrate", "--bucket", bucket, "--repo", "fixture/repo",
                                  "--base-branch", "develop", *extra, check=False)
        if check:
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors="replace"))
        return result

    def legacy_pulse_bucket(self):
        self.git(self.repo, "remote", "add", "origin", "https://github.com/marcusquinn/aidevops.git")
        named = self.root / "repo-feature-auto-20191231-000000-gh123"
        self.git(self.repo, "worktree", "move", self.work, named)
        self.work = named
        bucket = self.legacy_bucket()
        metadata = bucket / ".aidevops-worktree-recovery"
        for name, value in {"created-at": "2020-01-01T00:00:00Z", "producer": "worktree-helper.sh",
                            "producer-context": "recoverable-cleanup", "source-removal-outcome": "removed"}.items():
            (metadata / name).write_text(value + "\n")
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            lifecycle.managed_module().initialize(connection)
            connection.commit()
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        return bucket

    def test_legacy_pulse_retirement_without_restore_scratch(self):
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "local.ignored").write_bytes(b"retained ignored data")
        bucket = self.legacy_pulse_bucket()
        migration = json.loads(self.migrate_bucket(bucket).stdout)
        journal = json.loads(Path(migration["receipt"]).read_text())
        self.assertTrue(journal["legacy_pulse_compaction"])
        self.assertEqual(journal["phase"], "archived")
        self.assertNotIn("restore_inode", journal)
        self.assertEqual(self.migrate_bucket(bucket).returncode, 0)
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        result = json.loads(self.retirement("retire", bucket, "--confirm", plan["confirmation_token"]).stdout)
        self.assertTrue(result["retired"])
        self.assertFalse(bucket.exists())
        target = self.root / "test-only-restore"
        self.helper("restore", migration["archive"], "--target", target)
        self.assertEqual((target / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual(self.git(target, "show", ":mixed.txt"), b"staged\n")
        self.assertFalse((target / "local.ignored").exists())

    def test_legacy_pulse_preflight_retains_active_source(self):
        bucket = self.legacy_pulse_bucket()
        child = subprocess.Popen(  # nosec B603 -- current interpreter, constant sleep code, disposable fixture cwd
            [sys.executable, "-c", "import time; time.sleep(60)"], cwd=bucket)
        try:
            result = self.migrate_bucket(bucket, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"process-active", result.stdout)
            self.assertFalse(self.archives.exists())
            self.assertTrue(bucket.exists())
        finally:
            child.terminate()
            child.wait(timeout=10)

    def test_legacy_pulse_policy_rejects_wrong_evidence(self):
        from worktree_recovery_legacy_policy import validate
        bucket = self.legacy_pulse_bucket()
        metadata = bucket / ".aidevops-worktree-recovery"
        identity = {"format": "aidevops-worktree-recovery-v2", "producer": "worktree-helper.sh",
                    "producer_context": "recoverable-cleanup", "source_removal_outcome": "removed",
                    "created_at": "2020-01-01T00:00:00Z", "common_path": str(self.repo / ".git"),
                    "bucket_path": str(bucket), "source_path": str(self.work)}
        with patch.dict(os.environ, self.env):
            validate(identity)
            for changes in ({"producer": "profile-readme-helper.sh"},
                            {"source_path": "/fixture/manual-worktree"},
                            {"created_at": "2100-01-01T00:00:00Z"},
                            {"created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
                            {"common_path": str(metadata)}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    validate(dict(identity, **changes))
            with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as db:
                db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)", (str(self.work), "{}"))
                db.commit()
            with self.assertRaisesRegex(ValueError, "use-existing-lifecycle"):
                validate(identity)

    def test_legacy_pulse_only_relaxes_compaction_degraded_observation(self):
        bucket = self.legacy_pulse_bucket()
        command = ('source "$1"; capture_worktree_process_cwds() { return "$OBSERVATION_RC"; }; '
                   'identity=$(_worktree_recovery_plan_identity_json "$2") || exit 1; '
                   '_worktree_recovery_plan_process_state "$identity" "$3"')
        for observation, operation, expected in ((2, "", "unavailable"), (1, "compact-then-retire", "unavailable"),
                                                 (2, "compact-then-retire", "clear")):
            self.env["OBSERVATION_RC"] = str(observation)
            with self.subTest(observation=observation, operation=operation):
                result = self.run_command("bash", "-c", command, "legacy-fixture",
                                          HELPER.parent / "worktree-recovery-lifecycle-helper.sh",
                                          bucket, operation)
                self.assertEqual(result.stdout.decode().strip(), expected)

    def retirement_fixture(self):
        self.git(self.repo, "remote", "add", "origin", "https://github.com/marcusquinn/aidevops.git")
        bucket = self.legacy_bucket()
        managed = lifecycle.managed_module()
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            managed.initialize(connection)
            managed.enroll(connection, self.work)
            record = managed.load(connection, str(self.work))
            managed.seal(record)
            managed.save(connection, record)
            connection.commit()
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        migration = json.loads(self.migrate_bucket(bucket).stdout)
        return bucket, migration

    def retirement(self, action, bucket, *extra, check=True):
        result = self.run_command("bash", HELPER.parent / "worktree-recovery-lifecycle-helper.sh",
                                  action, "--bucket", bucket, *extra, check=False)
        if check:
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors="replace"))
        return result

    def test_compact_preserves_git_changes_and_untracked_not_ignored(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY")
        self.env["AIDEVOPS_WORKTREE_BASE_DIR"] = str(self.root)
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "new.txt").write_bytes(b"unique new file\n")
        (self.work / "cache.ignored").write_bytes(b"discardable cache\n")
        bucket = self.legacy_pulse_bucket()
        result = json.loads(self.retirement("compact", bucket).stdout)
        self.assertTrue(result["retired"])
        self.assertIsNone(result["confirmation_token"])
        self.assertFalse(bucket.exists())
        archive = Path(result["archive"])
        self.assertFalse((archive / "git-admin.json").exists())
        target = self.root / "compact-restored"
        self.helper("restore", archive, "--target", target)
        self.assertEqual(self.git(target, "show", ":mixed.txt"), b"staged\n")
        self.assertEqual((target / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual((target / "new.txt").read_bytes(), b"unique new file\n")
        self.assertFalse((target / "cache.ignored").exists())
        self.assertEqual(json.loads(self.retirement("compact", bucket).stdout), result)

    def test_compaction_maintenance_archives_then_retires_and_repeats(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY")
        (self.work / "new.txt").write_bytes(b"maintenance-owned payload\n")
        bucket = self.legacy_pulse_bucket()
        helper = HELPER.parent / "worktree-recovery-maintenance-helper.sh"
        result = json.loads(self.run_command("bash", helper, "compact").stdout)
        self.assertEqual(result["outcome"], "compacted", result)
        self.assertEqual(len(result["entries"]), 1)
        self.assertGreater(result["source_bytes_retired"], 0)
        self.assertGreater(result["archive_bytes"], 0)
        self.assertFalse(bucket.exists())
        repeated = json.loads(self.run_command("bash", helper, "compact").stdout)
        self.assertEqual(repeated["outcome"], "no-candidates", repeated)
        self.assertEqual(repeated["source_bytes_retired"], 0)

    def test_capture_rejects_hidden_index_changes(self):
        for flag in ("assume-unchanged", "skip-worktree"):
            with self.subTest(flag=flag):
                self.git(self.work, "update-index", "--" + flag, "mixed.txt")
                (self.work / "mixed.txt").write_bytes(b"hidden local change\n")
                result = self.helper("archive", self.work, "--repo", "fixture/repo",
                                     "--issue", "1", "--reason", "failed-worker",
                                     "--base-branch", "develop", "--output-root", self.archives, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"skip-worktree/assume-unchanged", result.stderr)
                self.assertEqual((self.work / "mixed.txt").read_bytes(), b"hidden local change\n")
                self.git(self.work, "update-index", "--no-" + flag, "mixed.txt")
        self.assertFalse(list(self.archives.rglob("manifest.json")))

    def test_verify_binds_untracked_payload_to_source_snapshot(self):
        (self.work / "new.txt").write_bytes(b"must survive\n")
        archive = self.archive()
        manifest_path = archive / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        (archive / "untracked.tar.gz").unlink()
        manifest["artifacts"] = [entry for entry in manifest["artifacts"]
                                 if entry["name"] != "untracked.tar.gz"]
        manifest_path.write_text(json.dumps(manifest))
        result = self.helper("verify", archive, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"untracked payload does not match captured source", result.stderr)

    def test_automatic_retirement_refuses_old_capture_without_untracked(self):
        self.env.pop("AIDEVOPS_WORKTREE_RECOVERY_POLICY")
        bucket = self.legacy_pulse_bucket()
        migration = json.loads(self.migrate_bucket(bucket).stdout)
        journal = Path(migration["receipt"])
        saved = json.loads(journal.read_text())
        saved["source"]["snapshot"]["schema"] = 2
        journal.write_text(json.dumps(saved))
        result = self.retirement("retire-automatic", bucket, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"automatic-requires-untracked-preservation", result.stdout)
        self.assertTrue(bucket.exists())
        self.assertFalse((journal.parent / "retirement.json").exists())

    def test_retirement_confirmed_and_independent_restore(self):
        (self.work / "local.ignored").write_bytes(b"retirement fixture")
        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        failed = self.retirement("retire", bucket, "--confirm", "wrong", check=False)
        self.assertIn(b"confirmation-mismatch", failed.stdout)
        self.assertTrue(bucket.exists())
        result = json.loads(self.retirement("retire", bucket, "--confirm", plan["confirmation_token"]).stdout)
        self.assertTrue(result["retired"])
        self.assertGreater(result["bucket_bytes"], 0)
        self.assertGreater(result["archive_bytes"], 0)
        self.assertFalse(bucket.exists())
        self.assertEqual(json.loads(self.retirement("retire-status", bucket).stdout), result)
        target = self.root / "retirement-restore"
        self.helper("restore", migration["archive"], "--target", target)
        self.assertFalse((target / "local.ignored").exists())

    def test_retirement_requires_available_base(self):
        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement('retire-plan', bucket).stdout)
        self.repo.rename(self.root / 'unavailable-base')
        result = self.retirement('retire', bucket, '--confirm', plan['confirmation_token'], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(bucket.is_dir())
        self.assertTrue(Path(migration['archive']).is_dir())

    def test_retirement_rejects_drift_and_archive_damage(self):
        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        receipt = json.loads(Path(migration["receipt"]).read_text())
        late = Path(receipt["source"]["identity"]["archive_path"]) / "late.ignored"
        late.write_bytes(b"late unique data")
        result = self.retirement("retire", bucket, "--confirm", plan["confirmation_token"], check=False)
        self.assertIn(b"source-drift", result.stdout)
        self.assertEqual(late.read_bytes(), b"late unique data")
        late.unlink()
        manifest = Path(migration["archive"]) / "manifest.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        result = self.retirement("retire", bucket, "--confirm", plan["confirmation_token"], check=False)
        self.assertIn(b"manifest-changed", result.stdout)
        self.assertTrue(bucket.is_dir())

    def test_retirement_resumes_claim_without_deleting_replacement(self):
        from worktree_recovery_migration_state import load
        from worktree_recovery_retirement_transaction import claim

        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        directory = Path(migration["receipt"]).parent
        record = load(directory / "retirement.json")
        target = claim(directory, record, bucket)
        self.assertTrue(target.is_dir())
        self.assertFalse(json.loads(self.retirement("retire-status", bucket).stdout)["retired"])
        bucket.mkdir()
        (bucket / "new-owner").write_bytes(b"must survive")
        result = json.loads(self.retirement("retire", bucket, "--confirm", plan["confirmation_token"]).stdout)
        self.assertTrue(result["retired"])
        self.assertEqual((bucket / "new-owner").read_bytes(), b"must survive")
        self.assertFalse(target.exists())

    def test_retirement_rootless_and_positive_process_guards(self):
        bucket, migration = self.retirement_fixture()
        identity = json.loads(Path(migration["receipt"]).read_text())["source"]["identity"]
        command = ('source "$1"; capture_worktree_process_cwds() { return 2; }; '
                   '_worktree_recovery_retirement_guard "$2"')
        args = ("bash", "-c", command, "retirement-fixture",
                HELPER.parent / "worktree-recovery-lifecycle-helper.sh", bucket)
        self.run_command(*args, input_data=json.dumps(identity).encode())
        positive = command.replace('return 2;', 'printf "%s\\n" "$RETIREMENT_FIXTURE_PATH"; return 2;')
        self.env["RETIREMENT_FIXTURE_PATH"] = str(bucket)
        result = self.run_command("bash", "-c", positive, "retirement-fixture",
                                  args[-2], bucket, input_data=json.dumps(identity).encode(), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"process-active", result.stdout)
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            connection.execute("DELETE FROM worktree_managed_lifetimes")
            connection.commit()
        result = self.run_command(*args, input_data=json.dumps(identity).encode(), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"process-unavailable", result.stdout)
        self.assertTrue(bucket.is_dir())

    def test_retirement_requires_migration_receipt(self):
        bucket = self.legacy_bucket()
        result = self.retirement("retire-plan", bucket, check=False)
        self.assertIn(b"migration-receipt-missing", result.stdout)
        self.assertTrue(bucket.is_dir())

    def test_retirement_keeps_owned_or_registered_copy(self):
        bucket, migration = self.retirement_fixture()
        linked = self.root / "registered"
        self.git(self.repo, "worktree", "add", linked, "feature/fixture")
        result = self.retirement("retire-plan", bucket, check=False)
        self.assertIn(b"worktree-reference-active", result.stdout)
        self.git(self.repo, "worktree", "remove", linked)
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            connection.execute("INSERT INTO worktree_owners(worktree_path,owner_pid,task_id,owner_session) VALUES (?,?,?,?)",
                               (str(bucket), os.getpid(), "fixture", "fixture"))
            connection.commit()
        result = self.retirement("retire-plan", bucket, check=False)
        self.assertIn(b"registry-active", result.stdout)
        self.assertTrue(bucket.is_dir())
        self.assertTrue(Path(migration["archive"]).is_dir())

    def test_retirement_killed_removal_retains_journal_and_late_data(self):
        import signal
        import worktree_recovery_retirement_transaction as transaction
        from worktree_recovery_migration_state import load

        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        directory = Path(migration["receipt"]).parent
        record = load(directory / "retirement.json")
        target = transaction.claim(directory, record, bucket)
        child = os.fork()
        if child == 0:
            with patch.object(transaction.shutil, "rmtree", side_effect=lambda *args, **kwargs:
                              os.kill(os.getpid(), signal.SIGKILL)):
                transaction.remove_claimed(directory, record, target)
            os._exit(99)
        _, status = os.waitpid(child, 0)
        self.assertTrue(os.WIFSIGNALED(status))
        self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
        report = json.loads(self.retirement("retire-status", bucket).stdout)
        self.assertEqual(report["state"], "removing")
        self.assertFalse(report["retired"])
        (target / "late-writer").write_bytes(b"must survive")
        result = self.retirement("retire", bucket, "--confirm", plan["confirmation_token"], check=False)
        self.assertIn(b"claimed-content-drift", result.stdout)
        self.assertEqual((target / "late-writer").read_bytes(), b"must survive")

    def test_retirement_rechecks_git_state_after_unclaimed_interruption(self):
        import worktree_recovery_retirement_transaction as transaction
        from worktree_recovery_migration_state import load

        bucket, migration = self.retirement_fixture()
        plan = json.loads(self.retirement("retire-plan", bucket).stdout)
        directory = Path(migration["receipt"]).parent
        record = load(directory / "retirement.json")
        with patch.object(transaction.os, "rename", side_effect=InterruptedError):
            with self.assertRaises(InterruptedError):
                transaction.claim(directory, record, bucket)
        self.assertEqual(load(directory / "retirement.json")["phase"], "claiming")
        new_head = self.git(self.repo, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "late ref update").decode().strip()
        # Legacy recovery copies have detached HEADs: change the copy itself,
        # not the original branch, which is no longer its HEAD authority.
        source = Path(load(Path(migration["receipt"]))["source"]["identity"]["archive_path"])
        self.git(source, "update-ref", "HEAD", new_head)
        result = self.retirement("retire", bucket, "--confirm", plan["confirmation_token"], check=False)
        self.assertIn(b"source-drift", result.stdout)
        self.assertTrue(bucket.is_dir())

    def test_legacy_migration_preserves_source_and_restores_independently(self):
        from worktree_recovery_migration_state import source_state

        (self.work / "history-only.bin").write_bytes(b"reflog-only fixture")
        self.git(self.work, "add", ".")
        self.git(self.work, "commit", "-qm", "history only")
        old = self.git(self.work, "rev-parse", "HEAD").decode().strip()
        (self.work / "mixed.txt").write_bytes(b"staged\n")
        self.git(self.work, "add", "mixed.txt")
        (self.work / "mixed.txt").write_bytes(b"unstaged\n")
        (self.work / "local.ignored").write_bytes(b"unique ignored fixture")
        bucket = self.legacy_bucket()
        (bucket / ".aidevops-worktree-recovery/worktree-gitfile").write_bytes(b"opaque extra provenance")
        result = json.loads(self.migrate_bucket(bucket).stdout)
        receipt = json.loads(Path(result["receipt"]).read_text())
        self.assertEqual(receipt["source"]["provenance"]["worktree-gitfile"]["hex"],
                         b"opaque extra provenance".hex())
        self.assertIn("worktree/.git", receipt["source"]["provenance"])
        self.assertEqual(receipt["source"], source_state(receipt["source"]["identity"], True, 3))
        self.assertFalse(result["source_retired"])
        self.assertEqual(result["reclaimed_bytes"], 0)
        self.assertIsNone(result["bucket_bytes"])
        self.assertGreater(result["archive_bytes"], 0)
        self.assertEqual(json.loads(self.migrate_bucket(bucket).stdout), result)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        self.assertFalse(list(Path(result["receipt"]).parent.glob(".restore-*")))
        self.assertFalse(list(Path(result["receipt"]).parent.glob(".cleanup-*")))
        self.assertTrue((Path(result["archive"]) / ".aidevops-archive-pin").is_file())
        plan = self.root / "plan.json"
        self.run_command("bash", HELPER.parent / "worktree-recovery-lifecycle-helper.sh",
                         "plan", "--output", plan)
        self.assertIn("compact-migration-protected", plan.read_text())
        restored = self.root / "independent-migration-restore"
        self.helper("restore", result["archive"], "--target", restored)
        self.assertFalse((restored / "local.ignored").exists())
        self.assertEqual(self.git(restored, "show", f"{old}:history-only.bin"), b"reflog-only fixture")
        self.assertEqual((restored / "mixed.txt").read_bytes(), b"unstaged\n")
        self.assertEqual(self.git(restored, "show", ":mixed.txt"), b"staged\n")
        self.assertTrue(bucket.is_dir())
        manifest = json.loads((Path(result['archive']) / 'manifest.json').read_text())
        self.assertFalse(manifest['self_contained'])
        self.repo.rename(self.root / 'unavailable-base')
        self.assertNotEqual(self.helper('verify', result['archive'], check=False).returncode, 0)

    def test_legacy_migration_resumes_verification_and_rejects_drift(self):
        from worktree_recovery_migration_state import publish

        bucket = self.legacy_bucket()
        first = json.loads(self.migrate_bucket(bucket).stdout)
        receipt_path = Path(first["receipt"])
        receipt = json.loads(receipt_path.read_text())
        # Model interruption after capture but before independent verification;
        # exercise the actual CLI again, without a fault-injection API.
        receipt["phase"] = "captured"
        for name in ("restore_slot", "restore_slot_inode", "restore_inode", "cleanup_slot"):
            receipt.pop(name, None)
        publish(receipt_path, receipt)
        resumed = json.loads(self.migrate_bucket(bucket).stdout)
        self.assertEqual(resumed, first)
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)
        before = receipt_path.read_bytes()
        worktree = Path(receipt["source"]["identity"]["archive_path"])
        (worktree / "late.txt").write_bytes(b"late writer")
        failure = self.migrate_bucket(bucket, check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn(b"source-drift", failure.stdout)
        self.assertEqual(receipt_path.read_bytes(), before)
        self.assertEqual((worktree / "late.txt").read_bytes(), b"late writer")
        self.assertEqual(len(list(self.archives.rglob("manifest.json"))), 1)

    def test_legacy_migration_incomplete_capture_never_allocates_again(self):
        from worktree_recovery_migration_state import publish

        bucket = self.legacy_bucket()
        first = json.loads(self.migrate_bucket(bucket).stdout)
        receipt_path = Path(first["receipt"])
        receipt = json.loads(receipt_path.read_text())
        receipt["phase"] = "capturing"
        publish(receipt_path, receipt)
        manifest = Path(first["archive"]) / "manifest.json"
        manifest.rename(manifest.with_name("manifest.partial"))
        before = sorted(path.relative_to(self.archives) for path in self.archives.rglob('*'))
        failure = self.migrate_bucket(bucket, check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn(b"capture-incomplete", failure.stdout)
        self.assertEqual(sorted(path.relative_to(self.archives) for path in self.archives.rglob('*')), before)
        self.assertFalse(list(self.archives.rglob('git-admin.json')))
        self.assertEqual(len(list(self.archives.rglob('manifest.partial'))), 1)
        self.assertTrue(bucket.is_dir())

    def test_legacy_migration_keeps_unsupported_permissions(self):
        (self.work / "local.txt").write_bytes(b"private fixture")
        (self.work / "local.txt").chmod(0o600)
        bucket = self.legacy_bucket()
        failure = self.migrate_bucket(bucket, check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn(b"special permissions", failure.stdout)
        self.assertFalse(list((bucket.parent / ".compact-migrations").rglob("journal.json")))
        self.assertFalse(list(self.archives.rglob("manifest.json")))
        self.assertTrue(bucket.is_dir())

    def test_legacy_migration_rejects_incomplete_and_missing_base(self):
        bucket = self.legacy_bucket()
        marker = bucket / ".aidevops-worktree-recovery/archive-complete"
        retained = marker.with_name("retained-marker")
        marker.rename(retained)
        failure = self.migrate_bucket(bucket, check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn(b"completion-marker-unavailable", failure.stdout)
        retained.rename(marker)
        self.repo.rename(self.root / "unavailable-repo")
        failure = self.migrate_bucket(bucket, check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn(b"git-recovery-unavailable", failure.stdout)
        self.assertFalse(list(self.archives.rglob("manifest.json")))
        self.assertTrue(marker.is_file())
        self.assertTrue(bucket.is_dir())

    def test_git_administration_bundle_omits_reachable_index_objects(self):
        from worktree_archive_snapshot import administration, administration_roots, bundle_roots

        state = administration(self.work)
        history = set(administration_roots(self.work, state, include_index=False))
        self.assertEqual(set(bundle_roots(self.work, state)), history)
        self.assertGreater(len(administration_roots(self.work, state)), len(history))

        (self.work / 'mixed.txt').write_text('unique staged contents\n')
        self.git(self.work, 'add', 'mixed.txt')
        staged = self.git(self.work, 'rev-parse', ':mixed.txt').decode().strip()
        self.assertEqual(set(bundle_roots(self.work, administration(self.work))), history | {staged})

        self.git(self.work, 'commit', '-qm', 'new contents')
        # This blob now exists only in historical trees, not the current HEAD tree.
        (self.work / 'historical-copy').write_text('base\n')
        self.git(self.work, 'add', 'historical-copy')
        state = administration(self.work)
        history = set(administration_roots(self.work, state, include_index=False))
        self.assertEqual(set(bundle_roots(self.work, state)), history)

    def test_git_administration_fetch_head_validation(self):
        from worktree_archive_administration import administration, fetch_head_roots, load_administration

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        self.assertEqual(fetch_head_roots(''), [])
        self.assertEqual(fetch_head_roots((b'a' * 64 + b'\t\tSHA256 fixture\n').hex()), ['a' * 64])
        payload = self.root / 'admin-payload'
        payload.mkdir()
        state = administration(self.work)
        for data in (b'bad line\n', b'0' * 40 + b'\t\tzero\n',
                     b'f' * 40 + b'\tunexpected\tflag\n', b'--option\t\tunsafe\n'):
            with self.subTest(data=data):
                (admin / 'FETCH_HEAD').write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'invalid_FETCH_HEAD'):
                    administration(self.work)
                state['files']['FETCH_HEAD'] = data.hex()
                (payload / 'git-admin.json').write_text(json.dumps(state))
                with self.assertRaisesRegex(ValueError, 'invalid_FETCH_HEAD'):
                    load_administration(payload)

    def test_git_administration_rejects_batch_command_injection(self):
        from worktree_archive_snapshot import administration, administration_roots

        state = administration(self.work)
        head = self.git(self.work, 'rev-parse', 'HEAD').strip()
        for suffix in (b'\nupdate refs/heads/injected ' + head,
                       b'\x00delete refs/heads/archive-head'):
            with self.subTest(suffix=suffix):
                state['files']['ORIG_HEAD'] = (head + suffix).hex()
                with self.assertRaisesRegex(ValueError, 'git_admin:invalid_object_id'):
                    administration_roots(self.work, state)

    def test_git_administration_rejects_unknown_operations_and_locks(self):
        import worktree_archive_snapshot as snapshots

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        for name in sorted(snapshots.OPERATIONS | {'index.lock', 'unknown-entry'}):
            with self.subTest(name=name):
                path = admin / name
                path.write_text('fixture')
                # Retain validation of legacy administration without asking the
                # current archive writer to create an obsolete archive format.
                with self.assertRaisesRegex(ValueError, 'git_admin:'):
                    snapshots.snapshot(self.work, True, True)
                self.assertTrue(path.exists())
                if name == 'index.lock':
                    default = self.helper('archive', self.work, '--repo', 'fixture/repo',
                                          '--issue', '2', '--reason', 'failed-worker',
                                          '--base-branch', 'develop', '--output-root', self.archives,
                                          check=False)
                    self.assertNotEqual(default.returncode, 0)
                    self.assertIn(b'git_admin:index_locked:index.lock', default.stderr)
                path.unlink()
        self.assertFalse(list(self.archives.rglob('manifest.json')))

    def test_readiness_administration_fails_closed(self):
        from worktree_archive_administration import administration, load_administration
        from worktree_archive_readiness import MAX_READINESS_BYTES

        admin = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir').decode().strip())
        state_dir = admin / 'aidevops'
        state_dir.mkdir()
        for name, reason in [('ownership.json', 'unknown_entry'),
                             ('js-install-partial', 'unfinished_operation')]:
            path = state_dir / name
            path.write_bytes(b'preserve this')
            with self.assertRaisesRegex(ValueError, f'git_admin:{reason}:aidevops/{name}'):
                administration(self.work)
            self.assertEqual(path.read_bytes(), b'preserve this')
            path.unlink()
        payload = self.root / 'malformed-admin'
        payload.mkdir()
        for name in ('aidevops/js-readiness.json', 'aidevops-profile-publication.json'):
            with self.subTest(name=name):
                path = admin / name
                path.symlink_to(self.work / 'mixed.txt')
                with self.assertRaisesRegex(ValueError, 'git_admin:symlink:'):
                    administration(self.work)
                path.unlink()
                path.write_bytes(b'x' * (MAX_READINESS_BYTES + 1))
                with self.assertRaisesRegex(ValueError, 'git_admin:readiness_too_large:'):
                    administration(self.work)
                path.write_bytes(b'bounded')
                state = administration(self.work)
                state['files'][name] = '00' * (MAX_READINESS_BYTES + 1)
                (payload / 'git-admin.json').write_text(json.dumps(state))
                with self.assertRaisesRegex(ValueError, 'git_admin:readiness_too_large:'):
                    load_administration(payload)

    def test_git_administration_rejects_location_dependent_config(self):
        import worktree_archive_snapshot as snapshots

        self.git(self.repo, 'config', 'extensions.worktreeConfig', 'true')
        self.git(self.work, 'config', '--worktree', 'core.worktree', str(self.work))
        with self.assertRaisesRegex(ValueError, 'git_admin:location_dependent_config:core.worktree'):
            snapshots.administration(self.work)

    @staticmethod
    def update_manifest(archive, **changes):
        path = archive / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest.update(changes)
        path.write_text(json.dumps(manifest) + "\n")

    def prune(self, mode="--apply", limit="20G"):
        return self.helper("prune", "--older-than", "14d", "--max-total-size", limit,
                           mode, "--output-root", self.archives)

    @staticmethod
    def prune_module():
        spec = importlib.util.spec_from_file_location("archive_prune", HELPER.with_name("worktree_archive_prune.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_pin_added_during_verification_preserves_claimed_archive(self):
        archive = self.archive()
        module = self.prune_module()
        entry = module.inspect(self.archives, archive, HELPER)
        original_verify = module.verify

        def pin_during_verify(helper, directory):
            original_verify(helper, directory)
            (directory / module.PIN).touch()

        with patch.object(module, "verify", pin_during_verify):
            with self.assertRaises(ValueError):
                module.remove_verified(self.archives, module.identity(self.archives), entry, HELPER)
        retained = list(self.archives.glob(".prune-*/archive"))
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / module.PIN).exists())
        self.helper("verify", retained[0])

    def test_replacement_at_original_name_is_never_deleted(self):
        archive = self.archive()
        module = self.prune_module()
        entry = module.inspect(self.archives, archive, HELPER)
        original_rename = os.rename

        def replace_after_claim(*args, **kwargs):
            original_rename(*args, **kwargs)
            archive.mkdir()
            (archive / "replacement-data").write_text("keep me")

        with patch.object(module.os, "rename", replace_after_claim):
            module.remove_verified(self.archives, module.identity(self.archives), entry, HELPER)
        self.assertEqual((archive / "replacement-data").read_text(), "keep me")

    def test_restore_never_overwrites_or_creates_through_tracked_symlinks(self):
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_text("unchanged")
        (self.work / "escape").symlink_to(sentinel)
        (self.work / "parent").symlink_to(outside)
        self.git(self.work, "add", "escape", "parent")
        for number, name in enumerate(("escape", "parent/new/file", "mixed.txt")):
            archive = self.archive()
            payload = archive / "untracked.tar.gz"
            with tarfile.open(payload, "w:gz") as output:
                member = tarfile.TarInfo(name)
                member.size = 7
                output.addfile(member, io.BytesIO(b"replace"))
            manifest = json.loads((archive / "manifest.json").read_text())
            manifest["artifacts"].append({"name": payload.name, "size": payload.stat().st_size,
                                          "sha256": hashlib.sha256(payload.read_bytes()).hexdigest()})
            self.update_manifest(archive, **manifest)
            target = self.root / f"restore-unsafe-{number}"
            self.assertNotEqual(self.helper("restore", archive, "--target", target,
                                           check=False).returncode, 0)
            self.assertEqual(sentinel.read_text(), "unchanged")
            self.assertFalse((outside / "new").exists())
            self.assertFalse(target.exists())  # Reject the unbound payload before creating a worktree.

    def test_gitignore_excludes_env_and_dependencies_not_tracked_examples(self):
        (self.work / ".gitignore").write_text(".env\nnode_modules/\n")
        (self.work / ".env").write_text("FIXTURE_ONLY=not-a-secret\n")
        (self.work / ".env.example").write_text("FIXTURE_ONLY=\n")
        self.git(self.work, "add", ".env.example")
        (self.work / "node_modules").mkdir()
        (self.work / "node_modules" / "cache").write_text("reinstall from lock\n")
        archive = self.archive()
        self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o700)
        target = self.root / "restored"
        self.helper("restore", archive, "--target", target)
        self.assertEqual(self.snapshot(self.work), self.snapshot(target))
        self.assertFalse((target / ".env").exists())
        self.assertFalse((target / "node_modules").exists())
        self.assertEqual((target / ".env.example").read_text(), "FIXTURE_ONLY=\n")

    def test_retention_preview_apply_and_repeat(self):
        old, recent = self.archive(), self.archive()
        self.update_manifest(old, created_at="2000-01-01T00:00:00Z")
        preview = self.prune("--dry-run").stdout.decode()
        self.assertIn(str(old), preview)
        self.assertNotIn(str(recent), preview)
        self.assertTrue(old.exists())
        self.prune()
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertEqual(self.prune().stdout, b"")

    def test_size_pressure_evicts_oldest_unpinned(self):
        old, recent = self.archive(), self.archive()
        yesterday = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
        self.update_manifest(old, created_at=yesterday.isoformat())
        recent_size = sum(path.stat().st_size for path in recent.iterdir())
        self.prune(limit=str(recent_size))
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())

    def test_pin_survives_age_and_size_pressure(self):
        archive = self.archive()
        self.update_manifest(archive, created_at="2000-01-01T00:00:00Z")
        (archive / ".aidevops-archive-pin").touch()
        self.prune(limit="1")
        self.assertTrue(archive.exists())
        self.helper("verify", archive)

    def test_corrupt_and_unknown_archives_are_preserved(self):
        for kind in ("hash", "missing", "empty-inventory", "extra", "naive-date", "non-object"):
            with self.subTest(kind=kind):
                archive = self.archive()
                self.update_manifest(archive, created_at="2000-01-01T00:00:00Z")
                if kind == "hash":
                    (archive / "diff.patch").write_text("corruption")
                elif kind == "missing":
                    (archive / "staged.patch").unlink()
                elif kind == "empty-inventory":
                    self.update_manifest(archive, artifacts=[])
                elif kind == "extra":
                    (archive / "unknown-recovery-data").write_text("preserve")
                elif kind == "naive-date":
                    self.update_manifest(archive, created_at="2000-01-01")
                else:
                    (archive / "manifest.json").write_text("[]")
                self.prune(limit="1")
                self.assertTrue(archive.exists())

    def test_symlinked_bucket_never_deletes_external_archive(self):
        archive = self.archive()
        self.update_manifest(archive, created_at="2000-01-01T00:00:00Z")
        bucket = archive.parent.parent
        outside = self.root / "outside"
        bucket.rename(outside)
        bucket.symlink_to(outside, target_is_directory=True)
        self.prune(limit="1")
        self.assertTrue((outside / archive.parent.name / archive.name).exists())

    def test_symlinked_artifact_is_rejected(self):
        archive = self.archive()
        outside = self.root / "outside.patch"
        (archive / "diff.patch").rename(outside)
        (archive / "diff.patch").symlink_to(outside)
        self.assertNotEqual(self.helper("verify", archive, check=False).returncode, 0)
        self.prune(limit="1")
        self.assertTrue(archive.exists())

    def snapshot(self, repo):
        entries = {}
        names = self.git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
        for raw in set(names.split(b"\0")) - {b""}:
            name = os.fsdecode(raw)
            path = repo / name
            if path.is_symlink():
                entries[name] = ("link", os.readlink(path))
            elif path.is_file():
                entries[name] = ("file", stat.S_IMODE(path.stat().st_mode),
                                 hashlib.sha256(path.read_bytes()).hexdigest())
            else:
                entries[name] = ("deleted",)
        return {
            "head": self.git(repo, "rev-parse", "HEAD"),
            "history": self.git(repo, "rev-list", "--parents", "--topo-order", "HEAD"),
            "index": self.git(repo, "ls-files", "--stage", "-z"),
            "staged": self.git(repo, "diff", "--cached", "--binary", "--no-ext-diff"),
            "unstaged": self.git(repo, "diff", "--binary", "--no-ext-diff"),
            "status": self.git(repo, "status", "--porcelain=v1", "-z", "-uall"),
            "files": entries,
        }

    def test_roundtrip_many_commits_merge_and_dirty_state_from_base_only(self):
        restore_repo = self.root / "base-only"
        self.run_command("git", "clone", "--no-local", self.repo, restore_repo)
        for number in range(30):
            (self.work / "history").write_text(f"commit {number}\n")
            self.git(self.work, "add", "history")
            self.git(self.work, "commit", "-qm", f"local {number}")
        self.git(self.work, "checkout", "-qb", "feature/side", "HEAD~10")
        for number in range(2):
            (self.work / "side").write_text(f"side {number}\n")
            self.git(self.work, "add", "side")
            self.git(self.work, "commit", "-qm", f"side {number}")
        self.git(self.work, "checkout", "-q", "feature/fixture")
        self.git(self.work, "merge", "--no-ff", "feature/side", "-m", "merge topology")
        (self.work / "mixed.txt").write_text("base\nstaged\n")
        (self.work / "binary.bin").write_bytes(bytes(range(255, -1, -1)))
        (self.work / "new-staged").write_text("new staged\n")
        (self.work / "run.sh").chmod(0o755)
        self.git(self.work, "rm", "staged-delete")
        self.git(self.work, "mv", "old-name", "renamed")
        self.git(self.work, "add", ".")
        (self.work / "mixed.txt").write_text("base\nstaged\nunstaged\n")
        (self.work / "binary.bin").write_bytes(b"\x00\xffunstaged\x00")
        (self.work / "new-staged").write_text("new staged\nunstaged too\n")
        (self.work / "unstaged-delete").unlink()
        (self.work / "notes").mkdir()
        for name, data in {"space name": b"text\n", "binary": b"\x00\xff",
                           "empty": b"", "line\nbreak": b"newline name\n"}.items():
            (self.work / "notes" / name).write_bytes(data)
        (self.work / "notes" / "executable").write_text("#!/bin/sh\nexit 0\n")
        (self.work / "notes" / "executable").chmod(0o755)
        (self.work / "notes" / "link").symlink_to("../mixed.txt")
        (self.work / "cache.ignored").write_text("documented exclusion\n")
        before = self.snapshot(self.work)
        self.assertEqual(len(before["history"].splitlines()), 34)
        archive = self.archive()
        self.assertEqual(self.git(restore_repo, "rev-list", "--count", "--all").strip(), b"1")
        self.assertNotEqual(self.run_command("git", "-C", restore_repo, "cat-file", "-e",
                                            before["head"].decode().strip(), check=False).returncode, 0)
        self.update_manifest(archive, source_git_common_dir=str(restore_repo / ".git"))
        self.helper("verify", archive)
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        target = self.root / "restored"
        self.helper("restore", archive, "--target", target)
        self.assertEqual(before, self.snapshot(target))
        self.git(target, "fsck", "--connectivity-only")
        self.assertFalse((target / "cache.ignored").exists())
        self.assertNotEqual(self.helper("restore", archive, "--target", target,
                                       check=False).returncode, 0)


    def managed_fixture(self):
        database = self.root / "registry.db"
        self.env.update(WORKTREE_REGISTRY_DB=str(database),
                        WORKTREE_REGISTRY_DIR=str(self.root),
                        AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.archives),
                        AIDEVOPS_CLEANUP_LOG=str(self.root / "cleanup.log"),
                        ORPHAN_LOCAL_COMMIT_ARCHIVE_SECS="86400",
                        ORPHAN_GENERATED_DIRTY_ARCHIVE_SECS="86400",
                        ORPHAN_GENERATED_CLEAN_ARCHIVE_SECS="86400",
                        WORKTREE_UNATTRIBUTED_RETENTION_DAYS="1")
        self.run_command("bash", "-c", 'source "$1/worktree-recovery-lifecycle-helper.sh"; _init_registry_db',
                         "registry-fixture", HELPER.parent)
        managed = lifecycle.managed_module()
        with closing(sqlite3.connect(database)) as connection:
            managed.initialize(connection)
            managed.enroll(connection, self.work)
            record = managed.load(connection, str(self.work))
            record["idle"] = {"policy": 1, "since": 100000, "monotonic_since": 100000,
                              "boot_id": managed.boot_id(), "generation": record["generation"],
                              "ownership_epoch": 0}
            managed.save(connection, record)
            connection.commit()
        return managed

    def prepare_managed(self, managed, idle_seconds=86400):
        arguments = lifecycle.argparse.Namespace(repo="fixture/repo", issue="1", base="develop", idle_seconds=idle_seconds)
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(lifecycle.time, "time", return_value=186401), \
                patch.object(lifecycle.time, "monotonic", return_value=186401):
            return Path(lifecycle.prepare(managed, self.work, arguments))

    def managed_record(self, managed):
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            return managed.load(connection, str(self.work))

    def test_stricter_configured_window_preserves_source_and_existing_recovery(self):
        managed = self.managed_fixture()
        with self.assertRaisesRegex(ValueError, "window incomplete"):
            self.prepare_managed(managed, 172800)
        self.assertNotIn("archive_operation", self.managed_record(managed))
        archived = self.prepare_managed(managed)
        with self.assertRaisesRegex(ValueError, "stricter idle window"):
            self.prepare_managed(managed, 172800)
        self.assertTrue(self.work.is_dir())
        self.assertTrue(archived.is_dir())

    def test_overlapping_archive_classes_honor_the_longest_configured_window(self):
        self.env.update(ORPHAN_LOCAL_COMMIT_ARCHIVE_SECS="172800",
                        ORPHAN_GENERATED_DIRTY_ARCHIVE_SECS="345600",
                        WORKTREE_UNATTRIBUTED_RETENTION_DAYS="3")
        script = 'source "$1/pulse-cleanup.sh"; _pc_ordinary_idle_window "" 1 1'
        result = self.run_command("bash", "-c", script, "_", HELPER.parent)
        self.assertEqual(result.stdout.strip(), b"345600")

    def test_managed_archive_restores_before_authorizing_removal(self):
        managed = self.managed_fixture()
        (self.work / "mixed.txt").write_text("unique dirty work\n")
        archive = self.prepare_managed(managed)
        record = self.managed_record(managed)
        operation = record["archive_operation"]
        self.assertEqual(operation["phase"], "verified")
        self.assertFalse((Path(operation["directory"]) / "restore").exists())
        self.assertTrue(self.work.is_dir())
        # Reusing verified recovery does not require space for another archive.
        usage = lifecycle.shutil.disk_usage(self.root)._replace(free=0)
        with patch.object(lifecycle.shutil, "disk_usage", return_value=usage):
            self.assertEqual(self.prepare_managed(managed), archive)
        self.assertEqual(len(list((self.archives / ".lifecycle").iterdir())), 1)
        proof = HELPER.with_name("worktree-managed-lifetime.py")
        self.run_command(sys.executable, proof, "proof", self.work)
        (self.work / "mixed.txt").write_text("changed after verification\n")
        self.assertNotEqual(self.run_command(sys.executable, proof, "proof", self.work, check=False).returncode, 0)
        self.assertTrue(self.work.is_dir())
        (self.work / "mixed.txt").write_text("unique dirty work\n")
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            connection.execute("INSERT INTO worktree_owners(worktree_path,owner_pid,task_id,owner_session) VALUES (?, ?, 'worktree-removal', ?)",
                               (str(self.work), os.getpid(), f"cleanup:{os.getpid()}"))
            connection.commit()
        result = self.run_command(sys.executable, proof, "proof", self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"owner remains alive", result.stderr)
        result = self.run_command(sys.executable, HELPER.with_name("worktree_lifetime_archive.py"),
                                  "ready", self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"owner remains alive", result.stderr)
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(self.work),))
            connection.commit()
        # Only remote policy is stubbed. Receipt reuse, source comparisons,
        # rootless native removal and final durable receipt use production paths.
        script = ('source "$1/pulse-cleanup.sh"; LOGFILE="$2"; '
                  '_pc_branch_archive_pr_state_clear() { return 0; }; '
                  '_pc_compact_archive_policy_clear() { return 0; }; '
                  'unregister_worktree() { return 0; }; '
                  '_pc_handle_confirmed_idle_archive "$3" "$4" feature/fixture 1 0 1 86401 fixture fixture/repo')
        self.run_command("bash", "-c", script, "_", HELPER.parent, self.root / "pulse.log", self.repo, self.work)
        self.assertFalse(self.work.exists())
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "removed")
        self.run_command(sys.executable, HELPER.with_name("worktree_lifetime_archive.py"), "removed", self.work)
        recovered = self.root / "recovered-after-removal"
        self.helper("restore", archive, "--target", recovered)
        self.assertEqual((recovered / "mixed.txt").read_text(), "unique dirty work\n")

    def test_missing_repository_is_not_a_completed_removal_receipt(self):
        managed = self.managed_fixture()
        self.prepare_managed(managed)
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        offline = self.root / "offline-repository"
        self.repo.rename(offline)
        command = (sys.executable, HELPER.with_name("worktree_lifetime_archive.py"), "removed", self.work)
        try:
            result = self.run_command(*command, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"repository unavailable", result.stderr)
            self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "verified")
        finally:
            offline.rename(self.repo)
        self.run_command(*command)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "removed")

    def test_lifecycle_report_is_read_only_and_not_authorization(self):
        managed = self.managed_fixture()
        database = Path(self.env["WORKTREE_REGISTRY_DB"])
        before = database.read_bytes()
        with patch.dict(os.environ, self.env, clear=True):
            observed = lifecycle_status.records(10)
        self.assertEqual(observed["status"], "available")
        self.assertEqual(observed["total"], 1)
        self.assertEqual(observed["entries"][0]["source"], "present")
        self.assertEqual(observed["entries"][0]["evidence"], "recorded-not-revalidated")
        # GH#35295: launcher provenance is reported, never inferred; absent
        # creation evidence stays unrecorded rather than human or scheduled.
        reported = observed["entries"][0]["lifecycle"]
        self.assertIn(reported["created_by"]["trigger"], ("unknown", "unrecorded"))
        self.assertEqual((reported["generation"], reported["attempts"], reported["last_attempt_by"]),
                         (self.managed_record(managed)["generation"], 0, None))
        self.assertEqual(database.read_bytes(), before)

    def test_lifecycle_reconcile_only_finalizes_verified_absent_sources(self):
        managed = self.managed_fixture()
        archived = self.prepare_managed(managed)
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(lifecycle_status.reconcile(10, 5)["attempted"], 0)
        self.assertTrue(self.work.is_dir())
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        with patch.dict(os.environ, self.env, clear=True):
            result = lifecycle_status.reconcile(10, 5)
            repeated = lifecycle_status.reconcile(10, 5)
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["deferred"], 0)
        self.assertEqual(repeated["attempted"], 0)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "removed")
        self.assertTrue(archived.is_dir())

    def test_missing_registry_report_does_not_create_evidence(self):
        missing = self.root / "missing-registry.db"
        with patch.dict(os.environ, {"WORKTREE_REGISTRY_DB": str(missing)}):
            observed = lifecycle_status.records(10)
            result = lifecycle_status.reconcile(10, 5)
        self.assertEqual(observed["status"], "unavailable")
        self.assertEqual(result["attempted"], 0)
        self.assertFalse(missing.exists())

    def test_reconcile_rotates_past_ineligible_rows_and_failed_candidates(self):
        managed = self.managed_fixture()
        self.prepare_managed(managed)
        self.git(self.repo, "worktree", "remove", "--force", self.work)
        failed = self.managed_record(managed)
        failed["identity"]["path"] = str(self.root / "a-invalid-generation")
        # Deliberately leave the operation's identity unchanged: this receipt
        # must fail validation, without monopolizing subsequent bounded runs.
        inactive = json.loads(json.dumps(failed))
        inactive["identity"]["path"] = str(self.root / "z-newer-inactive")
        inactive.pop("archive_operation")
        inactive["state"] = "created"
        with closing(sqlite3.connect(self.env["WORKTREE_REGISTRY_DB"])) as connection:
            for record in (failed, inactive):
                managed.save(connection, record)
            connection.commit()
        with patch.dict(os.environ, self.env, clear=True):
            results = [lifecycle_status.reconcile(1, 1) for _ in range(3)]
        self.assertEqual(sum(result["completed"] for result in results), 1)
        self.assertEqual(results[0]["deferred"], 1)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "removed")

    def test_standalone_scheduler_uses_user_units_and_bounded_cleanup(self):
        home = self.root / "scheduler-home"
        deployed = home / ".aidevops/agents/scripts/worktree-lifecycle-helper.sh"
        deployed.parent.mkdir(parents=True)
        deployed.touch()
        self.env.update(HOME=str(home), AIDEVOPS_LOG_DIR=str(home / "logs"))
        script = ('systemctl() { case "$*" in "--user status"|"--user daemon-reload"|'
                  '"--user enable --now aidevops-worktree-lifecycle.timer") return 0;; '
                  '*) return 1;; esac; }; source "$1" install-scheduler')
        result = self.run_command("bash", "-c", script, "_",
                                  HELPER.with_name("worktree-lifecycle-helper.sh"), check=False)
        units = home / ".config/systemd/user"
        if os.geteuid() == 0:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(units.exists())
            return
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        service = (units / "aidevops-worktree-lifecycle.service").read_text()
        timer = (units / "aidevops-worktree-lifecycle.timer").read_text()
        self.assertIn("worktree-lifecycle-helper.sh run", service)
        self.assertIn("TimeoutStartSec=900", service)
        self.assertIn("KillMode=control-group", service)
        self.assertIn("OnUnitActiveSec=600", timer)

    def test_pr_opened_after_archive_preserves_source(self):
        managed = self.managed_fixture()
        archive = self.prepare_managed(managed)
        marker = self.root / "fresh-policy-observed"
        script = ('source "$1/pulse-cleanup.sh"; LOGFILE="$2"; checks=0; marker="$5"; '
                  '_pc_branch_archive_pr_state_clear() { checks=$((checks + 1)); '
                  'if [[ "$checks" -eq 1 ]]; then return 0; fi; '
                  'if [[ "${AIDEVOPS_GH_PR_LIST_CACHE_DISABLE:-0}" == 1 && '
                  '"${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == 1 ]]; then touch "$marker"; fi; return 1; }; '
                  '_pc_compact_archive_policy_clear() { return 0; }; '
                  '_pc_handle_confirmed_idle_archive "$3" "$4" feature/fixture 1 0 0 86401 fixture fixture/repo')
        result = self.run_command("bash", "-c", script, "_", HELPER.parent, self.root / "pulse.log",
                                  self.repo, self.work, marker, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.is_file())
        self.assertTrue(self.work.is_dir())
        self.assertTrue(archive.is_dir())
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "verified")

    def test_interrupted_managed_archive_retains_one_attempt_and_source(self):
        managed = self.managed_fixture()
        original = lifecycle.helper

        def interrupted(*arguments):
            if arguments[0] == "restore":
                raise KeyboardInterrupt("simulated process loss before restore")
            return original(*arguments)

        with patch.object(lifecycle, "helper", side_effect=interrupted), self.assertRaises(KeyboardInterrupt):
            self.prepare_managed(managed)
        operation = self.managed_record(managed)["archive_operation"]
        self.assertEqual(operation["phase"], "building")
        with self.assertRaisesRegex(ValueError, "no duplicate allocation"):
            self.prepare_managed(managed)
        self.assertEqual(len(list((self.archives / ".lifecycle").iterdir())), 1)
        self.assertTrue(self.work.is_dir())
        proof = HELPER.with_name("worktree-managed-lifetime.py")
        self.assertNotEqual(self.run_command(sys.executable, proof, "proof", self.work, check=False).returncode, 0)

    def test_verified_scratch_cleanup_failure_is_resumable(self):
        managed = self.managed_fixture()
        with patch.object(lifecycle.shutil, "rmtree", side_effect=OSError("scratch cleanup unavailable")), self.assertRaises(OSError):
            self.prepare_managed(managed)
        operation = self.managed_record(managed)["archive_operation"]
        self.assertEqual(operation["phase"], "restore-verified")
        self.assertTrue((Path(operation["directory"]) / "restore").exists())
        proof = HELPER.with_name("worktree-managed-lifetime.py")
        self.assertNotEqual(self.run_command(sys.executable, proof, "proof", self.work, check=False).returncode, 0)
        archive = self.prepare_managed(managed)
        self.assertEqual(str(archive), operation["archive"])
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "verified")
        self.assertFalse((Path(operation["directory"]) / "restore").exists())
        self.assertTrue(self.work.is_dir())

    def test_failed_durability_never_publishes_removal_receipt(self):
        managed = self.managed_fixture()
        with patch.object(lifecycle, "durable_archive", side_effect=OSError("fsync unavailable")), self.assertRaises(OSError):
            self.prepare_managed(managed)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "blocked")
        self.assertTrue(self.work.is_dir())

    def test_manifest_change_after_restore_blocks_receipt(self):
        managed = self.managed_fixture()
        original = lifecycle.durable_archive

        def changed_manifest(archive):
            self.update_manifest(archive, reason="changed-after-restore")
            original(archive)

        with patch.object(lifecycle, "durable_archive", side_effect=changed_manifest), self.assertRaises(ValueError):
            self.prepare_managed(managed)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "blocked")
        self.assertTrue(self.work.is_dir())

    def test_intent_to_add_is_preserved_before_sealing(self):
        managed = self.managed_fixture()
        (self.work / "intent.txt").write_text("unfinished staging intent\n")
        self.git(self.work, "add", "--intent-to-add", "intent.txt")
        with self.assertRaisesRegex(ValueError, "intent-to-add"):
            self.prepare_managed(managed)
        self.assertNotIn("archive_operation", self.managed_record(managed))
        self.assertTrue((self.work / "intent.txt").exists())

    def test_capacity_counts_untracked_payload_before_reservation(self):
        managed = self.managed_fixture()
        (self.work / "large-untracked.bin").write_bytes(b"x" * (2 * 1024 ** 2))
        usage = lifecycle.shutil.disk_usage(self.root)._replace(free=1024 ** 3 + 1024 ** 2)
        with patch.object(lifecycle.shutil, "disk_usage", return_value=usage), self.assertRaisesRegex(ValueError, "capacity"):
            self.prepare_managed(managed)
        self.assertNotIn("archive_operation", self.managed_record(managed))
        self.assertTrue((self.work / "large-untracked.bin").exists())

    def test_special_metadata_is_protected_before_sealing(self):
        managed = self.managed_fixture()
        target = self.work / "untracked.txt"
        target.write_text("unique local content\n")
        target.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "permissions"):
            self.prepare_managed(managed)
        target.chmod(0o644)
        os.link(target, self.work / "hard-link")
        with self.assertRaisesRegex(ValueError, "hard links"):
            self.prepare_managed(managed)
        self.assertEqual(self.managed_record(managed)["state"], "created")
        self.assertNotIn("archive_operation", self.managed_record(managed))

    def test_unknown_git_administration_and_squash_drafts_are_preserved(self):
        managed = self.managed_fixture()
        admin = Path(self.git(self.work, "rev-parse", "--absolute-git-dir").decode().strip())
        for name in ("SQUASH_MSG", "private-draft", "COMMIT_EDITMSG"):
            with self.subTest(name=name):
                draft = admin / name
                draft.write_text("irreplaceable draft\n")
                try:
                    with self.assertRaises(ValueError):
                        self.prepare_managed(managed)
                    self.assertNotIn("archive_operation", self.managed_record(managed))
                    self.assertEqual(draft.read_text(), "irreplaceable draft\n")
                finally:
                    draft.unlink()

    def test_reflog_only_work_is_protected(self):
        managed = self.managed_fixture()
        (self.work / "mixed.txt").write_text("unpublished commit\n")
        self.git(self.work, "commit", "-qam", "unpublished")
        self.git(self.work, "reset", "--hard", "HEAD~1")
        with self.assertRaisesRegex(ValueError, "reflog-only"):
            self.prepare_managed(managed)
        self.assertNotIn("archive_operation", self.managed_record(managed))

    def test_managed_archive_failure_blocks_native_removal(self):
        managed = self.managed_fixture()
        with patch.object(lifecycle, "helper", side_effect=OSError("injected ENOSPC")), self.assertRaises(OSError):
            self.prepare_managed(managed)
        self.assertEqual(self.managed_record(managed)["archive_operation"]["phase"], "blocked")
        guard = HELPER.with_name("audit-worktree-removal-helper.sh")
        result = self.run_command("bash", "-c", 'source "$1"; _worktree_remove_with_native_git "$2" fixture fixture true',
                                  "_", guard, self.work, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.work.is_dir())


if __name__ == "__main__":
    unittest.main()
