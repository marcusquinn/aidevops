#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Unified creation/owner evidence and opt-in real rootless lifecycle POC."""

from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_lifetime_owner as owner
import worktree_lifetime_proof as proof

SPEC = importlib.util.spec_from_file_location("lifetime", SCRIPTS / "worktree-managed-lifetime.py")
lifetime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifetime)
RUN_SPEC = importlib.util.spec_from_file_location("managed_run", SCRIPTS / "worktree-managed-run.py")
runner = importlib.util.module_from_spec(RUN_SPEC)
RUN_SPEC.loader.exec_module(runner)
REG_SPEC = importlib.util.spec_from_file_location("registry_owner", SCRIPTS / "shared-worktree-registry-owner.py")
registry = importlib.util.module_from_spec(REG_SPEC)
REG_SPEC.loader.exec_module(registry)


class RunnerControlTests(unittest.TestCase):
    def test_nonterminal_service_never_inherits_tool_output_pipes(self):
        with patch.object(sys.stdin, "isatty", return_value=False), runner.isolated_service_io() as (stdio, _, mode):
            self.assertEqual(mode, "--pipe")
            self.assertEqual(stdio["stdin"], subprocess.DEVNULL)
            for key in ("stdout", "stderr"):
                self.assertTrue(stat.S_ISREG(os.fstat(stdio[key].fileno()).st_mode))

    def test_loaded_unit_without_invocation_is_pending_not_replaced(self):
        ready = {"InvocationID": "first", "MainPID": "0", "Job": "",
                 "ActiveState": "active", "SubState": "exited"}
        client = Mock()
        client.poll.return_value = None
        with patch.object(owner, "unit_snapshot", side_effect=[{"InvocationID": ""}, ready]), \
                patch.object(runner.time, "sleep"):
            self.assertEqual(runner.wait_for_unit("fixture", client, time.monotonic() + 1), ready)

    def test_deadline_refuses_without_waiting_for_client_eof(self):
        with self.assertRaises(ValueError):
            runner.wait_for_unit("fixture", Mock(), time.monotonic() - 1)


class OwnerEvidenceTests(unittest.TestCase):
    def test_completed_owner_release_requires_receipt_dead_pid_and_exact_generation(self):
        base = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
        cases = ("complete", "running", "unobserved", "live", "inaccessible", "changed-lease", "legacy")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(dir=base) as directory:
                database = str(Path(directory) / "owners.db")
                identity = {"path": "/fixture", "source_inode": "1:2"}
                snapshot = {"InvocationID": "invocation", "MainPID": "0", "Job": "",
                            "ExitType": "cgroup", "RemainAfterExit": "yes", "Restart": "no",
                            "ActiveState": "active", "SubState": "exited"}
                record = {"manager": owner.MANAGER, "state": "sealed", "sealed_at": time.time(),
                          "identity": identity, "admission_epoch": 0, "observed_admission_epoch": 0,
                          "launches": [{"kind": owner.KIND, "completion_evidence": "systemd-cgroup-v1",
                                        "invocation": "invocation", "quiescence": snapshot}]}
                if case == "running":
                    record["state"] = "running"
                if case == "unobserved":
                    record["admission_epoch"] = 1
                with closing(sqlite3.connect(database)) as db:
                    db.execute("""CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY,
                        owner_pid INTEGER, owner_process_start TEXT, created_at TEXT)""")
                    db.execute("INSERT INTO worktree_owners VALUES ('/fixture',123,'start','created')")
                    db.execute("CREATE TABLE worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT)")
                    if case != "legacy":
                        db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)", ("/fixture", json.dumps(record)))
                    db.commit()
                effect = None if case == "live" else PermissionError if case == "inaccessible" else ProcessLookupError
                with patch.object(owner, "identity", return_value=identity), patch.object(registry.os, "kill", side_effect=effect):
                    result = registry.release_completed([
                        database, "/fixture", "123", "changed" if case == "changed-lease" else "start", "created"])
                self.assertEqual(result, 0 if case == "complete" else 1)
                with closing(sqlite3.connect(database)) as db:
                    count = db.execute("SELECT count(*) FROM worktree_owners").fetchone()[0]
                self.assertEqual(count, 0 if case == "complete" else 1)

    @staticmethod
    def database():
        db = sqlite3.connect(":memory:")
        db.execute("""CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY,
                   owner_pid INTEGER, owner_session TEXT, owner_process_start TEXT,
                   task_id TEXT, owner_dead_seen_at TEXT)""")
        return db

    def test_uncontained_or_missing_cgroup_never_proves_completion(self):
        for observation in ({}, {"evidence": "observed", "cgroup": "/missing"},
                            {"evidence": "unavailable", "owner_pid": 99999999}):
            with self.subTest(observation=observation), self.assertRaises(ValueError):
                owner.drain(observation)

    def test_unavailable_process_is_recorded_not_invented(self):
        with patch.object(owner, "process_identity", side_effect=PermissionError):
            observation = owner.observe(123, "session")
        self.assertEqual(observation["evidence"], "unavailable")
        self.assertNotIn("completion_evidence", observation)

    def test_registration_transfer_and_legacy_boundary(self):
        identity = {"path": "/fixture", "source_inode": "1:2"}
        with closing(self.database()) as db, \
                patch.object(owner, "identity", return_value=identity), \
                patch.object(owner, "observe", side_effect=lambda pid, session: {
                    "kind": owner.KIND, "owner_pid": pid, "owner_session": session,
                    "evidence": "unavailable"}):
            owner.register(db, "/fixture", 1, "first")
            self.assertEqual(db.execute("SELECT count(*) FROM worktree_managed_lifetimes").fetchone()[0], 0)
            owner.register(db, "/fixture", 1, "first", creating=True)
            owner.register(db, "/fixture", 1, "first")
            owner.register(db, "/fixture", 2, "second")
            record = json.loads(db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0])
            self.assertEqual([launch["owner_pid"] for launch in record["launches"]], [1, 2])
            with self.assertRaises(ValueError):
                lifetime.seal(record)
            record["state"] = "sealed"
            db.execute("UPDATE worktree_managed_lifetimes SET record=?", (json.dumps(record),))
            with self.assertRaises(ValueError):
                owner.register(db, "/fixture", 3, "third")

    def test_generation_change_refuses(self):
        with closing(self.database()) as db, \
                patch.object(owner, "observe", return_value={"owner_pid": 1}), \
                patch.object(owner, "identity", return_value={"source_inode": "1:2"}) as identity:
            owner.register(db, "/fixture", 1, "first", creating=True)
            identity.return_value = {"source_inode": "1:3"}
            with self.assertRaises(ValueError):
                owner.register(db, "/fixture", 1, "first")

    def test_reboot_and_changed_invocation_refuse(self):
        launch = {"boot_id": "old", "unit": "aidevops-worker-fixture", "invocation": "first"}
        with self.assertRaises(ValueError):
            owner.drain_unit(launch, lambda: "new", lambda _: {})
        with self.assertRaises(ValueError):
            owner.drain_unit(launch, lambda: "old", lambda _: {"InvocationID": "second"})

    def test_live_descendants_refuse_even_after_parent_exit(self):
        launch = {"boot_id": "boot", "unit": "aidevops-worker-fixture", "invocation": "first"}
        snapshot = {"InvocationID": "first", "MainPID": "0", "Job": "",
                    "ActiveState": "active", "SubState": "running"}
        with self.assertRaises(ValueError):
            owner.drain_unit(launch, lambda: "boot", lambda _: snapshot)

    def test_incomplete_owner_receipt_refuses(self):
        record = {"manager": owner.MANAGER, "state": "sealed", "sealed_at": time.time(),
                  "identity": {"source_inode": "1:2"},
                  "launches": [{"kind": owner.KIND, "quiescence": {"MainPID": "0"}}]}
        with patch.object(owner, "drain", side_effect=ValueError("invocation changed")):
            with self.assertRaises(ValueError):
                proof.proof(record, "1:2")

    def test_raw_ownership_change_invalidates_admission_not_liveness_updates(self):
        with closing(self.database()) as db, \
                patch.object(owner, "observe", return_value={"owner_pid": 1}), \
                patch.object(owner, "identity", return_value={"source_inode": "1:2"}):
            db.execute("INSERT INTO worktree_owners VALUES ('/fixture',1,'session','start','task','')")
            owner.register(db, "/fixture", 1, "session", creating=True)
            db.execute("UPDATE worktree_owners SET owner_dead_seen_at='now'")
            owner.check_admission(db, "/fixture")
            db.execute("UPDATE worktree_owners SET owner_pid=2")
            with self.assertRaises(ValueError):
                owner.check_admission(db, "/fixture")

    def test_closed_managed_receipt_remains_valid_after_unit_collection(self):
        snapshot = {"InvocationID": "invocation", "MainPID": "0", "Job": "", "ExitType": "cgroup",
                    "RemainAfterExit": "yes", "Restart": "no", "ActiveState": "active", "SubState": "exited"}
        record = {"manager": owner.MANAGER, "state": "sealed", "sealed_at": time.time(),
                  "admission_epoch": 0, "observed_admission_epoch": 0,
                  "identity": {"source_inode": "1:2"},
                  "launches": [{"kind": owner.KIND, "completion_evidence": "systemd-cgroup-v1",
                                "invocation": "invocation", "quiescence": snapshot}]}
        with patch.object(owner, "unit_snapshot", side_effect=ValueError("unit collected")):
            proof.proof(record, "1:2")
        record["observed_admission_epoch"] = -1
        with self.assertRaises(ValueError):
            proof.proof(record, "1:2")


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
                      'AIDEVOPS_WORKTREE_CREATE_OWNER_PID="$$" '
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
