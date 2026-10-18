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


    def managed_fixture(self):
        database = self.root / "registry.db"
        self.env.update(WORKTREE_REGISTRY_DB=str(database),
                        AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(self.archives),
                        AIDEVOPS_CLEANUP_LOG=str(self.root / "cleanup.log"),
                        ORPHAN_LOCAL_COMMIT_ARCHIVE_SECS="86400",
                        ORPHAN_GENERATED_DIRTY_ARCHIVE_SECS="86400",
                        ORPHAN_GENERATED_CLEAN_ARCHIVE_SECS="86400",
                        WORKTREE_UNATTRIBUTED_RETENTION_DAYS="1")
        managed = lifecycle.managed_module()
        with closing(sqlite3.connect(database)) as connection:
            connection.execute("CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, owner_pid INTEGER, task_id TEXT, owner_session TEXT)")
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
            connection.execute("INSERT INTO worktree_owners VALUES (?, ?, 'worktree-removal', ?)",
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
        self.managed_fixture()
        database = Path(self.env["WORKTREE_REGISTRY_DB"])
        before = database.read_bytes()
        with patch.dict(os.environ, self.env, clear=True):
            observed = lifecycle_status.records(10)
        self.assertEqual(observed["status"], "available")
        self.assertEqual(observed["total"], 1)
        self.assertEqual(observed["entries"][0]["source"], "present")
        self.assertEqual(observed["entries"][0]["evidence"], "recorded-not-revalidated")
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
        target = self.work / "mixed.txt"
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
        for name in ("SQUASH_MSG", "private-draft"):
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
