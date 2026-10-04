#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise post-sync through the real audited recovery path in disposable repos."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
WORKER_KEYS = ("WORKER_WORKTREE_PATH", "WORKER_ISSUE_NUMBER", "WORKER_REPO_SLUG",
               "FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "Claude_HEADLESS",
               "CLAUDE_HEADLESS", "GITHUB_ACTIONS")


class PostSyncTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "repo"
        self.updater = self.root / "updater"
        self.remote = self.root / "remote.git"
        self.marker = self.root / "marker"
        self.config = self.home / ".config/aidevops/repos.json"
        self.config.parent.mkdir(parents=True)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in WORKER_KEYS and not key.startswith("GIT_")
                    and not key.startswith("AIDEVOPS_")}
        self.env.update(HOME=str(self.home), AIDEVOPS_REAL_GIT_BIN="/usr/bin/git")
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main", str(self.repo))
        self.identity(self.repo)
        (self.repo / "journal.json").write_text("seed\n")
        self.git("-C", str(self.repo), "add", ".")
        self.git("-C", str(self.repo), "commit", "-m", "seed")
        self.git("-C", str(self.repo), "remote", "add", "origin", str(self.remote))
        self.git("-C", str(self.repo), "push", "-u", "origin", "main")
        self.git("-C", str(self.remote), "symbolic-ref", "HEAD", "refs/heads/main")
        self.git("-C", str(self.repo), "remote", "set-head", "origin", "main")
        self.git("clone", str(self.remote), str(self.updater))
        self.identity(self.updater)
        self.before = self.git("-C", str(self.repo), "rev-parse", "HEAD")
        self.advance()

    def git(self, *args):
        return subprocess.run(  # nosec B603 -- fixed Git executable and test-owned fixture arguments
            ["/usr/bin/git", *args], env=self.env, check=True,
            capture_output=True, text=True, shell=False).stdout.strip()

    def identity(self, repo):
        for key, value in (("user.name", "Test"), ("user.email", "test@example.invalid"),
                           ("commit.gpgsign", "false")):
            self.git("-C", str(repo), "config", key, value)

    def advance(self):
        (self.updater / "journal.json").write_text("migration\n")
        self.git("-C", str(self.updater), "commit", "-am", "migration")
        self.git("-C", str(self.updater), "push", "origin", "main")
        self.after = self.git("-C", str(self.updater), "rev-parse", "HEAD")

    def declare(self, **changes):
        hook = {"when_changed": "journal.json", "run": [sys.executable, "-c",
                "import os, pathlib; p=pathlib.Path(" + repr(str(self.marker)) +
                "); p.write_text((p.read_text() if p.exists() else '') + os.getcwd() + '\\n')"]}
        hook.update(changes)
        self.entry = {"path": str(self.repo), "role": "maintainer", "post_sync": [hook]}
        self.write_config()

    def write_config(self):
        self.config.write_text(json.dumps({"initialized_repos": [self.entry]}))
        self.config.chmod(0o600)

    def sync(self, command="fast-forward-current", **env):
        args = ["bash", str(SCRIPTS / "canonical-recovery-helper.sh"), command,
                "--repo", str(self.repo), "--issue", "33603", "--confirm"]
        args.append("FAST_FORWARD_CANONICAL_BRANCH" if command == "fast-forward-current"
                    else "SYNCHRONIZE_CANONICAL_MIRROR")
        if command == "fast-forward-current":
            args.extend(["--branch", "main"])
        result = subprocess.run(  # nosec B603 -- repository helper and exclusively fixture-owned argv
            args, env=dict(self.env, **env), capture_output=True,
            text=True, timeout=30, shell=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("-C", str(self.repo), "rev-parse", "HEAD"), self.after)
        self.assertEqual(self.git("-C", str(self.repo), "status", "--porcelain"), "")
        return result.stdout + result.stderr

    def test_matching_hook_runs_once_and_records_evidence(self):
        self.declare()
        self.assertIn("POST_SYNC outcome=success", self.sync())
        self.sync()
        self.assertEqual(self.marker.read_text(), str(self.repo) + "\n")
        log = self.home / ".aidevops/logs/canonical-post-sync.jsonl"
        receipts = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["before"], self.before)
        self.assertEqual(receipts[0]["after"], self.after)
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)

    def test_mirror_sync_runs_hook(self):
        self.declare()
        self.assertIn("POST_SYNC outcome=success", self.sync("sync-mirror"))

    def test_undeclared_repo_unchanged(self):
        self.assertNotIn("POST_SYNC", self.sync())
        self.assertFalse(self.marker.exists())

    def test_unmatched_path_does_not_run(self):
        self.declare(when_changed="other.json")
        self.assertNotIn("POST_SYNC", self.sync())
        self.assertFalse(self.marker.exists())

    def test_failure_does_not_rollback_and_hides_output(self):
        self.declare(run=[sys.executable, "-c", "print('SECRET_SENTINEL'); raise SystemExit(7)"])
        output = self.sync()
        self.assertIn("POST_SYNC outcome=failed hook=0 exit_code=7", output)
        self.assertIn("WARNING", output)
        self.assertNotIn("SECRET_SENTINEL", output)

    def test_timeout_does_not_rollback(self):
        self.declare(run=[sys.executable, "-c", "import time; time.sleep(10)"], timeout_seconds=1)
        self.assertIn("POST_SYNC outcome=timeout", self.sync())

    def test_fifo_evidence_log_does_not_block_sync(self):
        self.declare()
        log = self.home / ".aidevops/logs/canonical-post-sync.jsonl"
        log.parent.mkdir(parents=True)
        os.mkfifo(log, 0o600)
        output = self.sync()
        self.assertIn("POST_SYNC outcome=success", output)
        self.assertIn("evidence_log_unavailable", output)

    def test_malformed_registry_warns_without_traceback(self):
        self.declare()
        self.config.write_text(json.dumps({"initialized_repos": [None]}))
        output = self.sync()
        self.assertIn("POST_SYNC outcome=warning", output)
        self.assertNotIn("Traceback", output)
        self.assertFalse(self.marker.exists())

    def test_invalid_later_hook_prevents_all_execution(self):
        self.declare()
        self.entry["post_sync"].append({"when_changed": "../journal.json", "run": ["true"]})
        self.write_config()
        self.assertIn("POST_SYNC outcome=warning", self.sync())
        self.assertFalse(self.marker.exists())

    def test_worker_cannot_trigger_hook(self):
        self.declare()
        output = self.sync(WORKER_WORKTREE_PATH="worker", AIDEVOPS_HEADLESS="false")
        self.assertIn("POST_SYNC outcome=skipped reason=worker_session", output)
        self.assertFalse(self.marker.exists())

    def test_headless_cannot_trigger_hook(self):
        self.declare()
        self.assertIn("reason=worker_session", self.sync(AIDEVOPS_HEADLESS="1"))
        self.assertFalse(self.marker.exists())

    def test_contributor_config_cannot_trigger_hook(self):
        self.declare()
        self.entry["role"] = "contributor"
        self.write_config()
        self.assertIn("POST_SYNC outcome=warning", self.sync())
        self.assertFalse(self.marker.exists())

    def test_writable_config_cannot_trigger_hook(self):
        self.declare()
        self.config.chmod(0o666)
        self.assertIn("POST_SYNC outcome=warning", self.sync())
        self.assertFalse(self.marker.exists())

    def test_override_cannot_declare_hook(self):
        self.declare()
        override = self.root / "override.json"
        self.config.rename(override)
        self.assertNotIn("POST_SYNC", self.sync(AIDEVOPS_REPOS_CONFIG=str(override)))
        self.assertFalse(self.marker.exists())

    def test_shell_string_is_rejected(self):
        self.declare(run="touch marker")
        self.assertIn("POST_SYNC outcome=warning", self.sync())
        self.assertFalse(self.marker.exists())

    def test_symlink_config_is_rejected(self):
        self.declare()
        target = self.root / "target.json"
        self.config.rename(target)
        self.config.symlink_to(target)
        self.assertIn("POST_SYNC outcome=warning", self.sync())
        self.assertFalse(self.marker.exists())

    def test_rename_matches_deleted_source_and_destination_directory(self):
        self.declare()
        destination = self.updater / "migrations"
        destination.mkdir()
        self.git("-C", str(self.updater), "mv", "journal.json", "migrations/journal.json")
        self.git("-C", str(self.updater), "commit", "-m", "move migration journal")
        self.git("-C", str(self.updater), "push", "origin", "main")
        self.after = self.git("-C", str(self.updater), "rev-parse", "HEAD")
        self.entry["post_sync"].append(dict(self.entry["post_sync"][0], when_changed="migrations/"))
        self.write_config()
        output = self.sync()
        self.assertEqual(output.count("POST_SYNC outcome=success"), 2)
        self.assertEqual(self.marker.read_text(), (str(self.repo) + "\n") * 2)


if __name__ == "__main__":
    unittest.main()
