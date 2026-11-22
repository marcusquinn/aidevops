#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Opt-in real rootless owner lifecycle POC (AIDEVOPS_TEST_SYSTEMD=1)."""

from contextlib import closing
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_lifetime_owner as owner


@unittest.skipUnless(os.environ.get("AIDEVOPS_TEST_SYSTEMD") == "1", "explicit native user-systemd POC")
class NativeOwnerCycle(unittest.TestCase):
    def test_managed_success_and_error_return_pipe_eof(self):
        for command, expected in ((["true"], 0), (["bash", "-c", "exit 7"], 7)):
            with self.subTest(command=command):
                result = subprocess.run(
                    [sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                     "--timeout-seconds", "3", "--", *command],
                    capture_output=True, text=True, timeout=6, check=False)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_creation_work_descendant_completion_archive_restore(self):
        base = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        self.assertTrue(base.is_dir())
        with tempfile.TemporaryDirectory(prefix="owner-lifecycle-poc-", dir=base) as temporary:
            root = Path(temporary)
            repo, work = root / "repo", root / "work"
            home = root / "home"
            home.mkdir()
            git = os.environ.get("AIDEVOPS_TEST_GIT_BIN", shutil.which("git"))
            env = dict(os.environ, HOME=str(home), WORKTREE_REGISTRY_DIR=str(root / "registry"),
                       WORKTREE_REGISTRY_DB=str(root / "registry/registry.db"),
                       AIDEVOPS_WORKTREE_ARCHIVE_ROOT=str(root / "archives"),
                       AIDEVOPS_REPOS_FILE=str(home / "repos.json"),
                       AIDEVOPS_CLEANUP_LOG=str(root / "cleanup.log"),
                       AIDEVOPS_WORKTREE_BASE_DIR=str(root),
                       WORKTREE_NODE_MODULES_RESTORE_ENABLED="0")
            env["PATH"] = str(Path(git).parent) + os.pathsep + env["PATH"]
            def run(*argv, check=True):
                return subprocess.run([str(arg) for arg in argv], env=env, capture_output=True,
                                      text=True, check=check, timeout=60)
            def git_run(path, *args):
                return run(git, "-C", path, *args).stdout
            run(git, "init", "-q", "-b", "main", repo)
            (repo / "tracked").write_text("base\n")
            git_run(repo, "add", "tracked")
            git_run(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "-qm", "base")
            unit = ""
            launcher = None
            log = root / "managed-run.log"
            # The production shared creator runs as the invocation leader's child.
            # Work stays in this real user-service cgroup, including a setsid child.
            script = ('set -eu; source "$1/shared-worktree-create.sh"; '
                      'worktree_create_registered "$2" "$3" HEAD -b poc; '
                      'exec "$4" -c "$5" "$3"')
            workload = ("import pathlib,subprocess,sys,time,os; p=pathlib.Path(sys.argv[1]); "
                        "(p/'tracked').write_text('committed\\n'); "
                        "subprocess.run(['git','-C',str(p),'add','tracked'],check=True); "
                        "subprocess.run(['git','-C',str(p),'-c','user.name=Fixture','-c',"
                        "'user.email=fixture@example.invalid','commit','-qm','work'],check=True); "
                        "(p/'tracked').write_text('staged\\n'); "
                        "subprocess.run(['git','-C',str(p),'add','tracked'],check=True); "
                        "(p/'tracked').write_text('unstaged\\n'); "
                        "(p/'untracked').write_text('excluded\\n'); "
                        "subprocess.Popen(['sleep','8'],cwd=p,start_new_session=True); "
                        "(p.parent/'ready').write_text(str(os.getpid())); time.sleep(1)")
            try:
                with log.open("w") as output:
                    launcher = subprocess.Popen(
                        ["bash", str(SCRIPTS / "worktree-helper.sh"), "run", "--timeout-seconds", "45", "--",
                         "bash", "-c", script, "owner-poc", str(SCRIPTS), str(repo), str(work), sys.executable, workload],
                        env=env, stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 20
                while not (root / "ready").exists() and time.monotonic() < deadline:
                    if launcher.poll() is not None:
                        break
                    time.sleep(0.1)
                self.assertTrue((root / "ready").exists(), log.read_text())
                helper = [sys.executable, SCRIPTS / "worktree-managed-lifetime.py"]
                record = json.loads(run(*helper, "status", work).stdout)
                self.assertEqual(record["manager"], owner.MANAGER)
                self.assertEqual(record["launches"][0].get("completion_evidence"), "systemd-cgroup-v1", record)
                time.sleep(1.2)
                self.assertNotEqual(run(*helper, "seal", work, check=False).returncode, 0)
                self.assertNotEqual(run(*helper, "proof", work, check=False).returncode, 0)
                guard = SCRIPTS / "audit-worktree-removal-helper.sh"
                guard_script = 'source "$1"; worktree_removal_guard "$2" owner-poc owner-poc'
                self.assertNotEqual(run("bash", "-c", guard_script, "poc", guard, work, check=False).returncode, 0)
                commands = [("rev-parse", "HEAD"), ("ls-files", "--stage"),
                            ("diff", "--cached", "--binary"), ("diff", "--binary")]
                before = [git_run(work, *args) for args in commands]
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    sealed = run(*helper, "seal", work, check=False)
                    if sealed.returncode == 0:
                        break
                    time.sleep(0.2)
                self.assertEqual(sealed.returncode, 0, sealed.stderr)
                self.assertEqual(launcher.wait(timeout=15), 0, log.read_text())
                run(*helper, "proof", work)
                run("bash", "-c", guard_script, "poc", guard, work)
                captured = run(sys.executable, SCRIPTS / "worktree_recovery_producer.py",
                               "capture", work, root / "archives", "owner-poc", "git-only")
                archive = Path(captured.stdout.strip())
                # Production guarded removal, not rmtree as a substitute for
                # completed ownership. Native force handles preserved Git dirt;
                # allow_degraded is false, so the process guard is not bypassed.
                run("bash", "-c", 'source "$1"; remove_archived_worktree_path "$2" "$3" '
                    'owner-poc owner-poc "" false true', "poc", guard, work, archive)
                self.assertFalse(work.exists())
                restored = root / "restored"
                run("bash", SCRIPTS / "worktree-archive-helper.sh", "restore", archive, "--target", restored)
                self.assertEqual(before, [git_run(restored, *args) for args in commands])
                self.assertFalse((restored / "untracked").exists())
                restored_record = json.loads(run(*helper, "status", restored).stdout)
                self.assertEqual(restored_record["manager"], owner.MANAGER)
                self.assertNotEqual(run(*helper, "proof", restored, check=False).returncode, 0)
                previous = json.loads(run(*helper, "status", work).stdout)
                failed = run("bash", "-c", 'source "$1/shared-worktree-create.sh"; '
                             'worktree_create_registered "$2" "$3" missing-fixture-ref --detach',
                             "failed-recreate", SCRIPTS, repo, work, check=False)
                self.assertNotEqual(failed.returncode, 0)
                self.assertFalse(work.exists())
                self.assertNotEqual(run(*helper, "proof", work, previous["identity"]["source_inode"],
                                        check=False).returncode, 0)
                run("bash", "-c", 'source "$1/shared-worktree-create.sh"; '
                    'worktree_create_registered "$2" "$3" HEAD -b second',
                    "recreate", SCRIPTS, repo, work)
                replacement = json.loads(run(*helper, "status", work).stdout)
                self.assertNotEqual(replacement["generation"], previous["generation"])
                self.assertEqual(replacement["state"], "running")
                self.assertNotEqual(run(*helper, "proof", work, check=False).returncode, 0)
                with closing(sqlite3.connect(env["WORKTREE_REGISTRY_DB"])) as db:
                    historical = db.execute("SELECT record FROM worktree_lifetime_history WHERE path=? AND generation=?",
                                            (str(work), previous["generation"])).fetchone()
                self.assertEqual(json.loads(historical[0]), previous)
            finally:
                # Only this fixture's unique service; production/session services untouched.
                match = re.search(r"Managed worktree run: (aidevops-worker-session-[a-f0-9]+\.service)",
                                  log.read_text() if log.exists() else "")
                if match:
                    unit = match[1]
                    run("systemctl", "--user", "stop", unit, check=False)
                    run("systemctl", "--user", "reset-failed", unit, check=False)
                if launcher is not None:
                    launcher.wait(timeout=15)


if __name__ == "__main__":
    unittest.main()
