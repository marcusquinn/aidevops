#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the real compact archive CLI in disposable local Git repositories."""

import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "worktree-archive-helper.sh"


class ArchiveLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="archive-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
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

    def run_command(self, *args, check=True):
        result = subprocess.run(  # nosec B603 -- fixture-owned Git/Bash argv, no shell expansion
            [str(arg) for arg in args], env=self.env,
            capture_output=True, timeout=60, check=False)
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
            self.assertEqual((target / "mixed.txt").read_text(), "base\n")

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


if __name__ == "__main__":
    unittest.main()
