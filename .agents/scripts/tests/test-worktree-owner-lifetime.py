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
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_lifetime_owner as owner
import worktree_lifetime_proof as proof

SPEC = importlib.util.spec_from_file_location("lifetime", SCRIPTS / "worktree-managed-lifetime.py")
lifetime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifetime)
REG_SPEC = importlib.util.spec_from_file_location("registry_owner", SCRIPTS / "shared-worktree-registry-owner.py")
registry = importlib.util.module_from_spec(REG_SPEC)
REG_SPEC.loader.exec_module(registry)


class CreationProducerTests(unittest.TestCase):
    def test_persistent_producers_register_new_branches_and_reuse_worktrees(self):
        base = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
        with tempfile.TemporaryDirectory(prefix="skill-creation-", dir=base) as directory:
            root = Path(directory)
            repo, home = root / "repo", root / "home"
            home.mkdir()
            git = os.environ.get("AIDEVOPS_TEST_GIT_BIN", shutil.which("git"))
            env = dict(os.environ, HOME=str(home), WORKTREE_REGISTRY_DIR=str(root / "registry"),
                       WORKTREE_REGISTRY_DB=str(root / "registry/owners.db"))
            env["PATH"] = str(Path(git).parent) + os.pathsep + env["PATH"]

            def command(*args):
                result = subprocess.run([str(arg) for arg in args], env=env, text=True,
                                        capture_output=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            command(git, "init", "-q", "-b", "main", repo)
            command(git, "-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--allow-empty", "-qm", "fixture")
            command(git, "-C", repo, "branch", "existing")
            script = ('source "$1/skill-update-pr-lib.sh"; WORKTREE_HELPER="$2/missing"; '
                      'log_info() { return 0; }; log_error() { printf "%s\\n" "$*" >&2; return 0; }; '
                      '_create_worktree_for_branch "$3" "$2/repo" fixture')
            for branch in ("new", "existing", "new"):
                with self.subTest(branch=branch):
                    path = command("bash", "-c", script, "fixture", SCRIPTS, root, branch)
                    self.assertEqual(path, str(root / ("repo-" + branch)))
                    self.assertTrue((Path(path) / ".git").is_file())
            script = ('source "$1/pulse-quality-debt.sh"; '
                      'create_quality_debt_worktree "$2/repo" 123 fixture')
            for attempt in range(2):
                with self.subTest(producer="quality-debt", attempt=attempt):
                    path = command("bash", "-c", script, "fixture", SCRIPTS, root)
                    self.assertEqual(path, str(root / "repo-bugfix-qd-123-fixture"))
                    self.assertTrue((Path(path) / ".git").is_file())
            with closing(sqlite3.connect(env["WORKTREE_REGISTRY_DB"])) as db:
                self.assertEqual(db.execute("SELECT branch FROM worktree_owners ORDER BY branch").fetchall(),
                                 [("bugfix/qd-123-fixture",), ("existing",), ("new",)])
            command(git, "clone", "--bare", "-q", repo, root / "origin.git")
            command(git, "-C", repo, "remote", "add", "origin", str(root / "origin.git"))
            script = ('source "$1/shared-todo-commit.sh"; '
                      '_todo_create_planning_worktree "$2/repo" "plan: fixture" main '
                      '0123456789abcdef "$2/planning.log" || exit 1; '
                      'printf "%s\\n" "$_TODO_PLANNING_PR_WORKTREE"')
            path = command("bash", "-c", script, "fixture", SCRIPTS, root)
            self.assertTrue((Path(path) / ".git").is_file())
            with closing(sqlite3.connect(env["WORKTREE_REGISTRY_DB"])) as db:
                self.assertEqual(db.execute("SELECT branch FROM worktree_owners WHERE worktree_path=?",
                                            (path,)).fetchone(), ("HEAD",))
            cleanup = subprocess.run(["bash", "-c",
                                      'source "$1/shared-todo-commit.sh"; _todo_remove_temp_worktree "$2" "$3"',
                                      "fixture", str(SCRIPTS), str(repo), path], env=env,
                                     text=True, capture_output=True, timeout=15)
            legacy = sys.platform == "darwin" or env.get("AIDEVOPS_WORKTREE_MANAGER") == "legacy-guards"
            self.assertEqual(cleanup.returncode == 0, legacy, cleanup.stderr)
            self.assertEqual(Path(path).exists(), not legacy)
            # Source release functions from a fixture linked checkout, so their
            # bootstrap cannot create a control worktree in the real repository.
            source = root / "repo-new"
            (source / "aidevops.sh").touch()
            (source / ".agents/scripts").mkdir(parents=True)
            (source / ".agents/scripts/version-manager.sh").touch()
            command(git, "-C", repo, "tag", "v1.0.0")
            script = ('source "$1/full-loop-release-helper.sh" help >/dev/null; '
                      '_full_loop_release_prepare_control_worktree "$2/repo" || exit 1; '
                      '_full_loop_release_prepare_tag_worktree v1.0.0 || exit 1; '
                      'tag_path="$_FULL_LOOP_RELEASE_PATH"; '
                      'release_lane_pin_snapshot() { return 0; }; '
                      '_full_loop_capture_release_authorization() { return 1; }; '
                      'if _full_loop_release_prepare_new fixture/repo 1 "$2/release-prepare" unused 1; '
                      'then exit 1; fi; '
                      'trap - EXIT; printf "%s\\n%s\\n%s\\n" '
                      '"$_FULL_LOOP_RELEASE_CONTROL_PATH" "$tag_path" "$_FULL_LOOP_RELEASE_PATH"')
            result = subprocess.run(["bash", "-c", script, "fixture", str(SCRIPTS), str(root)],
                                    cwd=source, env=dict(env, AIDEVOPS_WORKTREE_BASE_DIR=str(root),
                                                         AIDEVOPS_STATE_DIR=str(root / "state")),
                                    text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            paths = result.stdout.strip().splitlines()
            self.assertEqual(len(paths), 3, result.stdout)
            self.assertEqual(paths[-1], str(root / "release-prepare"))
            with closing(sqlite3.connect(env["WORKTREE_REGISTRY_DB"])) as db:
                for release_path in paths:
                    self.assertTrue((Path(release_path) / ".git").is_file())
                    self.assertEqual(db.execute("SELECT branch FROM worktree_owners WHERE worktree_path=?",
                                                (release_path,)).fetchone(), ("HEAD",))

    def test_reserved_paths_and_registration_failure_preserve_sources(self):
        base = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
        with tempfile.TemporaryDirectory(prefix="reserved-creation-", dir=base) as directory:
            root = Path(directory)
            repo = root / "repo"
            git = os.environ.get("AIDEVOPS_TEST_GIT_BIN") or shutil.which("git")
            env = dict(os.environ, HOME=str(root), WORKTREE_REGISTRY_DIR=str(root / "registry"),
                       WORKTREE_REGISTRY_DB=str(root / "registry/owners.db"))
            env["PATH"] = str(Path(git).parent) + os.pathsep + env["PATH"]
            subprocess.run([git, "init", "-q", "-b", "main", str(repo)], env=env, check=True, timeout=10)
            subprocess.run([git, "-C", str(repo), "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                            "commit", "--allow-empty", "-qm", "fixture"], env=env, check=True, timeout=10)
            script = ('source "$1/shared-worktree-create.sh"; '
                      'worktree_create_registered "$2" "$3" HEAD --detach')

            def create(path, **updates):
                return subprocess.run(["bash", "-c", script, "fixture", str(SCRIPTS), str(repo), str(path)],
                                      env=dict(env, **updates), capture_output=True, text=True, timeout=15)

            reserved = root / "reserved"
            reserved.mkdir()
            self.assertNotEqual(create(reserved).returncode, 0)
            result = create(reserved, AIDEVOPS_WORKTREE_CREATE_RESERVED_PATH=str(reserved))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((reserved / ".git").is_file())
            nonempty = root / "nonempty"
            nonempty.mkdir()
            (nonempty / "keep").write_text("preserve")
            self.assertNotEqual(create(nonempty, AIDEVOPS_WORKTREE_CREATE_RESERVED_PATH=str(nonempty)).returncode, 0)
            self.assertEqual((nonempty / "keep").read_text(), "preserve")
            link = root / "link"
            link.symlink_to(nonempty, target_is_directory=True)
            self.assertNotEqual(create(link, AIDEVOPS_WORKTREE_CREATE_RESERVED_PATH=str(link)).returncode, 0)
            blocked = root / "blocked"
            blocked.write_text("not a registry directory")
            retained = root / "retained"
            result = create(retained, WORKTREE_REGISTRY_DIR=str(blocked), WORKTREE_REGISTRY_DB=str(blocked / "db"))
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((retained / ".git").is_file(), result.stderr)
            self.assertIn("Worktree retained", result.stderr)


class OwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        platform = patch.object(sys, "platform", "linux")
        platform.start()
        self.addCleanup(platform.stop)

    def test_macos_creation_keeps_legacy_guards_without_manufacturing_managed_proof(self):
        with closing(self.database()) as db, patch.object(sys, "platform", "darwin"), \
                patch.object(owner, "identity", return_value={"path": "/fixture", "source_inode": "1:2"}), \
                patch.object(owner, "observe") as observe:
            owner.register(db, "/fixture", 123, "legacy", creating=True)
            record = json.loads(db.execute("SELECT record FROM worktree_creation_backends").fetchone()[0])
            self.assertEqual(record["backend"], "legacy-guards")
            self.assertEqual(db.execute("SELECT count(*) FROM worktree_managed_lifetimes").fetchone()[0], 0)
            observe.assert_not_called()

    def test_legacy_selection_cannot_downgrade_existing_managed_generation(self):
        with closing(self.database()) as db, \
                patch.object(owner, "identity", return_value={"path": "/fixture", "source_inode": "1:2"}), \
                patch.object(owner, "observe", return_value={"owner_pid": 123}):
            owner.register(db, "/fixture", 123, "managed", creating=True)
            with patch.dict(os.environ, AIDEVOPS_WORKTREE_MANAGER="legacy-guards"):
                owner.register(db, "/fixture", 123, "managed", creating=True)
            record = json.loads(db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0])
            self.assertEqual(record["manager"], owner.MANAGER)
            with self.assertRaises(ValueError):
                lifetime.seal(record)

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
                record.update({"running": {"state": "running"},
                               "unobserved": {"admission_epoch": 1}}.get(case, {}))
                with closing(sqlite3.connect(database)) as db:
                    db.execute("""CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY,
                        owner_pid INTEGER, owner_process_start TEXT, created_at TEXT)""")
                    db.execute("INSERT INTO worktree_owners VALUES ('/fixture',123,'start','created')")
                    db.execute("CREATE TABLE worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT)")
                    if case != "legacy":
                        db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)", ("/fixture", json.dumps(record)))
                    db.commit()
                effect = {"live": None, "inaccessible": PermissionError}.get(case, ProcessLookupError)
                with patch.object(owner, "identity", return_value=identity), patch.object(registry.os, "kill", side_effect=effect):
                    result = registry.release_completed([
                        database, "/fixture", "123", "changed" if case == "changed-lease" else "start", "created"])
                self.assertEqual(result, int(case != "complete"))
                with closing(sqlite3.connect(database)) as db:
                    count = db.execute("SELECT count(*) FROM worktree_owners").fetchone()[0]
                self.assertEqual(count, int(case != "complete"))

    def test_rotation_fences_inode_reuse_and_rollback_preserves_fence(self):
        cases = ("closed", "running", "missing-receipt", "unobserved", "same-source", "same-admin",
                 "same-identities", "foreign", "stale-token")
        for case in cases:
            with self.subTest(case=case), closing(self.database()) as db:
                previous = {"path": "/fixture", "source_inode": "1:2", "admin_inode": "1:3"}
                current = dict(previous, source_inode="1:4", admin_inode="1:5")
                snapshot = {"InvocationID": "invocation", "MainPID": "0", "Job": "",
                            "ExitType": "cgroup", "RemainAfterExit": "yes", "Restart": "no",
                            "ActiveState": "active", "SubState": "exited"}
                record = {"manager": owner.MANAGER, "generation": "a" * 32, "state": "sealed",
                          "sealed_at": time.time(), "identity": previous,
                          "admission_epoch": 0, "observed_admission_epoch": 0,
                          "launches": [{"kind": owner.KIND, "completion_evidence": "systemd-cgroup-v1",
                                        "invocation": "invocation", "quiescence": snapshot}]}
                if case == "running":
                    record["state"] = "running"
                elif case == "missing-receipt":
                    record["launches"][0].pop("quiescence")
                elif case == "unobserved":
                    record["admission_epoch"] = 1
                elif case == "same-source":
                    current["source_inode"] = previous["source_inode"]
                elif case == "same-admin":
                    current["admin_inode"] = previous["admin_inode"]
                elif case == "same-identities":
                    current = dict(previous)
                elif case == "foreign":
                    record["manager"] = "pulse-cgroup-v1"
                encoded = json.dumps(record)
                db.execute("CREATE TABLE worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT)")
                db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?,?)", ("/fixture", encoded))
                db.commit()
                db.execute("BEGIN IMMEDIATE")
                if case in ("running", "missing-receipt", "unobserved", "foreign"):
                    with self.assertRaises(ValueError):
                        owner.begin_creation(db, "/fixture")
                    db.rollback()
                    self.assertEqual(db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0], encoded)
                    continue
                token = owner.begin_creation(db, "/fixture")
                db.commit()  # This durable fence precedes the native Git operation.
                pending = db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0]
                with self.assertRaises(ValueError):
                    proof.proof(json.loads(pending), previous["source_inode"])
                db.execute("BEGIN IMMEDIATE")
                with patch.object(owner, "identity", return_value=current), \
                        patch.object(owner, "observe", return_value={"evidence": "unavailable"}), \
                        patch.dict(os.environ, AIDEVOPS_WORKTREE_CREATION_TOKEN="stale" if case == "stale-token" else token):
                    if case != "stale-token":
                        owner.prepare_creation(db, "/fixture")
                        self.assertEqual(db.execute("SELECT record FROM worktree_lifetime_history").fetchone()[0], encoded)
                        owner.register(db, "/fixture", 1, "replacement", creating=True)
                        replacement = json.loads(db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0])
                        self.assertNotEqual(replacement["generation"], record["generation"])
                        with self.assertRaises(ValueError):
                            proof.proof(replacement, current["source_inode"])
                    else:
                        with self.assertRaises(ValueError):
                            owner.prepare_creation(db, "/fixture")
                # Failure after Git creation must NOT revive the old sealed proof.
                db.rollback()
                self.assertEqual(db.execute("SELECT record FROM worktree_managed_lifetimes").fetchone()[0], pending)
                self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='worktree_lifetime_history'").fetchone())

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

    def test_raw_owner_path_move_invalidates_both_generations(self):
        with closing(self.database()) as db, \
                patch.object(owner, "observe", return_value={"owner_pid": 1}), \
                patch.object(owner, "identity", return_value={"source_inode": "1:2"}):
            db.execute("INSERT INTO worktree_owners VALUES ('/source',1,'session','start','task','')")
            for path in ("/source", "/target"):
                owner.register(db, path, 1, "session", creating=True)
                owner.check_admission(db, path)
            db.execute("UPDATE worktree_owners SET worktree_path='/target' WHERE worktree_path='/source'")
            for path in ("/source", "/target"):
                with self.assertRaises(ValueError):
                    owner.check_admission(db, path)

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


class ProcessReconciliationTests(unittest.TestCase):
    def record(self):
        return {"manager": owner.MANAGER, "state": "running", "admission_epoch": 2,
                "observed_admission_epoch": 2, "launches": [
                    {"kind": owner.KIND, "boot_id": "11111111-1111-1111-1111-111111111111",
                     "owner_pid": number, "owner_start": "10"} for number in (100, 101)]}

    def test_finished_history_is_retained_and_not_polled_again(self):
        import worktree_lifetime_reconcile as reconcile
        record = self.record()
        with patch.object(owner, "recorded_process_status", side_effect=[
                {"status": "pid-absent"}, {"status": "same-process-alive"}]) as observe:
            self.assertEqual(reconcile.reconcile(record), {"finished": 1, "active": 1, "unknown": 0})
            self.assertEqual(observe.call_count, 2)
        with patch.object(owner, "recorded_process_status", return_value={"status": "unknown"}) as observe:
            self.assertEqual(reconcile.reconcile(record), {"finished": 1, "active": 0, "unknown": 1})
            self.assertEqual(observe.call_count, 1)
        self.assertEqual(len(record["launches"]), 2)
        self.assertEqual(record["state"], "running")
        self.assertNotIn("observation_quiescence", record["launches"][0])
        record["launches"][0]["owner_start"] = "11"
        self.assertFalse(reconcile.finished(record["launches"][0]))

    def test_previous_boot_does_not_require_old_pid_or_invocation(self):
        launch = self.record()["launches"][0]
        with patch.object(owner, "boot_id", return_value="22222222-2222-2222-2222-222222222222"), \
                patch.object(owner, "process_identity", side_effect=AssertionError("old boot PID inspected")):
            self.assertEqual(owner.recorded_process_status(launch)["status"], "previous-boot")

    def test_matching_reused_denied_and_absent_pid_are_distinct(self):
        launch = self.record()["launches"][0]
        cases = (("10", "same-process-alive"), ("20", "pid-reused"),
                 (PermissionError(), "unknown"), (FileNotFoundError(), "pid-absent"))
        for value, expected in cases:
            options = {"side_effect": value} if isinstance(value, Exception) else {"return_value": value}
            with self.subTest(expected=expected), patch.object(owner, "boot_id", return_value=launch["boot_id"]), \
                    patch.object(owner, "process_identity", **options), \
                    patch.object(os.path, "lexists", return_value=False):
                self.assertEqual(owner.recorded_process_status(launch)["status"], expected)

    def test_incomplete_admission_refuses_reconciliation(self):
        import worktree_lifetime_reconcile as reconcile
        record = self.record()
        record["admission_epoch"] += 1
        with self.assertRaisesRegex(ValueError, "ownership changed"):
            reconcile.reconcile(record)

    def test_dead_parent_does_not_bypass_populated_or_unknown_group(self):
        import worktree_lifetime_reconcile as reconcile
        record = self.record()
        with patch.object(owner, "recorded_process_status", return_value={"status": "pid-absent"}):
            reconcile.reconcile(record)
        launch = record["launches"][0]
        with patch.object(owner, "boot_id", return_value=launch["boot_id"]), \
                self.assertRaisesRegex(ValueError, "same-boot parent"):
            reconcile.quiescence(launch)
        with patch.object(owner, "boot_id", return_value="22222222-2222-2222-2222-222222222222"):
            launch["observation_quiescence"] = reconcile.quiescence(launch)
            reconcile.validate_quiescence(launch)
        self.assertNotIn("completion_evidence", launch)
        self.assertNotIn("invocation", launch)

    def test_inconsistent_or_malformed_receipts_are_not_deletion_proof(self):
        import worktree_lifetime_reconcile as reconcile
        record = self.record()
        with patch.object(owner, "recorded_process_status", return_value={"status": "pid-absent"}), \
                patch.object(owner, "boot_id", return_value="22222222-2222-2222-2222-222222222222"):
            reconcile.reconcile(record)
            launch = record["launches"][0]
            receipt = reconcile.quiescence(launch)
        for field, value in (("observed_boot", launch["boot_id"]), ("observed_boot", "malformed"),
                             ("group", "absent"), ("group", "generation-retired"), ("group", "empty")):
            launch["observation_quiescence"] = dict(receipt, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                reconcile.validate_quiescence(launch)
        launch["observation_quiescence"] = receipt
        launch["owner_pid"] = None
        self.assertFalse(reconcile.finished(launch))

    def test_seal_checks_every_launch_and_preserves_distinct_receipt_contract(self):
        import worktree_lifetime_reconcile as reconcile
        record = self.record()
        record["identity"] = {"source_inode": "fixture-inode"}
        with patch.object(owner, "boot_id", return_value="22222222-2222-2222-2222-222222222222"):
            lifetime.seal(record)
            proof.proof(record, "fixture-inode")
        self.assertEqual(record["state"], "sealed")
        self.assertTrue(all(reconcile.finished(launch) for launch in record["launches"]))
        del record["launches"][0]["observation_quiescence"]
        with self.assertRaisesRegex(ValueError, "observation completion"):
            proof.proof(record, "fixture-inode")


class ProcessSnapshotTests(unittest.TestCase):
    def snapshot(self):
        return {"status": "available", "boot_id": "11111111-1111-1111-1111-111111111111",
                "processes": {100: {"start": "10", "state": "S", "cgroup": "/user/aidevops-worker-one.service"}},
                "uncertain_pids": [], "membership_unavailable": False}

    def managed(self):
        return {"manager": "pulse", "created_by": {"entrypoint": "pulse"}, "state": "running",
                "launches": [{"unit": "aidevops-worker-one", "invocation": "a" * 32,
                              "boot_id": self.snapshot()["boot_id"],
                              "cgroup": "/user/aidevops-worker-one.service"}]}

    def test_snapshot_distinguishes_process_identity_absence_and_uncertainty(self):
        import worktree_process_snapshot as census
        launch = ProcessReconciliationTests().record()["launches"][0]
        snapshot = self.snapshot()
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "same-process-alive")
        launch["owner_start"] = "20"
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "pid-reused")
        snapshot["processes"].clear()
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "pid-absent")
        snapshot["uncertain_pids"] = [100]
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "unknown")
        snapshot["status"] = "unavailable"
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "unknown")

    def test_empty_or_failed_process_listing_is_unavailable(self):
        import worktree_process_snapshot as census
        for output in ("", "malformed"):
            with self.subTest(output=output), patch.object(subprocess, "check_output", return_value=output):
                self.assertEqual(census.capture()["status"], "unavailable")

    def test_managed_activity_uses_processes_not_retained_unit_objects(self):
        import worktree_process_snapshot as census
        snapshot, record = self.snapshot(), self.managed()
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        snapshot["processes"][100]["cgroup"] += "/child"
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        snapshot["processes"][100]["cgroup"] = "/user/aidevops-worker-one.service-other"
        self.assertEqual(census.activity(record, snapshot)["state"], "not-observed")
        self.assertFalse(census.activity(record, snapshot)["deletion_authorized"])

    def test_unknown_admission_membership_and_provenance_do_not_become_idle(self):
        import worktree_process_snapshot as census
        snapshot, record = self.snapshot(), self.managed()
        snapshot["processes"].clear()
        snapshot["membership_unavailable"] = True
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        snapshot["membership_unavailable"] = False
        snapshot["runtime_inspection_unavailable"] = [200]
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        snapshot["runtime_inspection_unavailable"] = []
        record["launches"][0]["invocation"] = None
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        record["manager"] = "owner-cgroup"
        self.assertEqual(census.activity(record, snapshot)["reason"], "pulse-management-unrecorded")

    def test_runtime_directory_positive_match_protects_legacy_without_enrollment(self):
        import worktree_process_snapshot as census
        arguments = ["bash", "/agents/scripts/headless-runtime-helper.sh", "run",
                     "--role", "worker", "--dir", "/worktree", "--prompt", "never-report-this"]
        self.assertEqual(census.worker_directory(arguments), "/worktree")
        arguments[4] = "pulse"
        self.assertIsNone(census.worker_directory(arguments))
        snapshot = self.snapshot()
        snapshot["processes"][100]["worker_worktree"] = "/worktree"
        record = {"manager": "owner-cgroup", "identity": {"path": "/worktree"}}
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        self.assertEqual(record["manager"], "owner-cgroup")

    def test_malformed_managed_identities_remain_unknown(self):
        import worktree_process_snapshot as census
        snapshot = self.snapshot()
        snapshot["processes"].clear()
        cases = (("launch", "boot_id", "invalid"), ("launch", "invocation", "invalid"),
                 ("launch", "unit", []), ("launch", "cgroup", "relative/aidevops-worker-one.service"),
                 ("launch", "cgroup", "/user/./aidevops-worker-one.service"),
                 ("launch", "cgroup", "//user/aidevops-worker-one.service"),
                 ("record", "identity", []), ("record", "identity", False),
                 ("record", "identity", 0), ("record", "identity", ""), ("record", "identity", None))
        for scope, key, value in cases:
            record = self.managed()
            targets = {"launch": record["launches"][0], "record": record}
            targets[scope][key] = value
            with self.subTest(scope=scope, key=key, value=value):
                self.assertEqual(census.activity(record, snapshot)["state"], "unknown")

    def test_batch_negative_is_revalidated_before_completion_is_persisted(self):
        import worktree_lifetime_reconcile as reconcile
        record, snapshot = ProcessReconciliationTests().record(), self.snapshot()
        snapshot["processes"].clear()
        with patch.object(owner, "recorded_process_status", return_value={"status": "same-process-alive"}):
            self.assertEqual(reconcile.reconcile(record, snapshot), {"finished": 0, "active": 2, "unknown": 0})
        self.assertTrue(all("process_completion" not in launch for launch in record["launches"]))


if __name__ == "__main__":
    unittest.main()
