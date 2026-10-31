#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Managed runner capability, startup and output-transport contracts."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
owner = importlib.import_module("worktree_lifetime_owner")
native_git = importlib.import_module("native_git")

SPEC = importlib.util.spec_from_file_location("managed_run", SCRIPTS / "worktree-managed-run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerControlTests(unittest.TestCase):
    def test_service_preserves_admission_requirements_not_parent_identity(self):
        keys = ("RUNTIME_PID", "SESSION_ID", "GENERATION_ID", "RUN_ID")
        environment = {"AIDEVOPS_LIFECYCLE_" + key: "parent" for key in keys}
        environment["AIDEVOPS_LIFECYCLE_STATE_DIR"] = "/fixture/state"
        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(runner.inherited_environment(), [
                "--setenv=AIDEVOPS_LIFECYCLE_GENERATION_ID",
                "--setenv=AIDEVOPS_LIFECYCLE_RUN_ID",
                "--setenv=AIDEVOPS_LIFECYCLE_STATE_DIR",
            ])

    def test_lifecycle_entry_executes_with_its_own_native_identity(self):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "Bash is required for the lifecycle entry test")
        with tempfile.TemporaryDirectory(prefix="managed-lifecycle-") as directory:
            environment = dict(os.environ, HOME=directory,
                               AIDEVOPS_LIFECYCLE_STATE_DIR=directory + "/state",
                               AIDEVOPS_LIFECYCLE_RUNTIME_PID="1",
                               AIDEVOPS_LIFECYCLE_SESSION_ID="parent")
            command = [bash, str(SCRIPTS / "worker-lifecycle-state.sh"),
                       sys.executable, "-c", "import os; "
                       "assert os.environ['AIDEVOPS_LIFECYCLE_RUNTIME_PID'] == str(os.getpid()); "
                       "assert os.environ['AIDEVOPS_LIFECYCLE_SESSION_ID'] != 'parent'"]
            result = subprocess.run(  # nosec B603 # resolved Bash, fixed fixture argv, no shell
                command,
                cwd=directory, env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            environment.update(AIDEVOPS_LIFECYCLE_GENERATION_ID="invalid",
                               AIDEVOPS_LIFECYCLE_RUN_ID="invalid")
            denied = subprocess.run(  # nosec B603 # repeats the fixed fixture argv above
                command, cwd=directory, env=environment,
                capture_output=True, text=True, timeout=15)
            self.assertEqual(denied.returncode, 75, denied.stderr)

    def test_native_enrichment_exec_preserves_managed_admission(self):
        if not runner.backend_available():
            self.skipTest("rootless user-systemd unavailable")
        git = native_git.real_git()
        with tempfile.TemporaryDirectory(prefix="enrichment-managed-") as directory:
            root = Path(directory)
            repo, remote = root / "repo", root / "remote.git"
            env = dict(os.environ, HOME=str(root), AIDEVOPS_WORKTREE_BASE_DIR=str(root / "trees"),
                       AIDEVOPS_LIFECYCLE_STATE_DIR=str(root / "lifecycle"),
                       WORKTREE_REGISTRY_DIR=str(root / "registry"),
                       WORKTREE_REGISTRY_DB=str(root / "registry/registry.db"),
                       AIDEVOPS_LOG_DIR=str(root / "logs"), LOGFILE=str(root / "pulse.log"),
                       GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
                       GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            for args in (("init", "--bare", str(remote)), ("init", "-b", "main", str(repo)),
                         ("-C", str(repo), "commit", "--allow-empty", "-m", "base"),
                         ("-C", str(repo), "remote", "add", "origin", str(remote)),
                         ("-C", str(repo), "push", "-u", "origin", "main"),
                         ("-C", str(repo), "remote", "set-head", "origin", "main")):
                subprocess.run(  # nosec B603 # resolved native Git and fixed disposable setup
                    [git, *args], env=env, capture_output=True, check=True, timeout=15)
            configuration = root / ".config/aidevops"
            configuration.mkdir(parents=True)
            (configuration / "repos.json").write_text(json.dumps({
                "initialized_repos": [{"path": str(repo), "slug": "owner/repo"}],
            }))
            runtime = root / "runtime.sh"
            runtime.write_text('#!/usr/bin/env bash\nset -euo pipefail\n'
                f'source "{SCRIPTS}/shared-constants.sh"\n'
                'branch=$(git -C "$WORKER_WORKTREE_PATH" symbolic-ref --short HEAD)\n'
                'claim_worktree_ownership "$WORKER_WORKTREE_PATH" "$branch" '
                '--owner-pid "$$" --session enrichment-fixture --task 502\n')
            runtime.chmod(0o700)
            env["HEADLESS_RUNTIME_HELPER"] = str(runtime)
            prompt = root / "prompt"
            prompt.write_text("fixture, no model or GitHub access")
            helper = str(SCRIPTS / "pulse-enrichment-run-helper.sh")
            result = subprocess.run(  # nosec B603 # fixed interpreter and owned fixture paths
                [sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                "--timeout-seconds", "90", "--after", "bash", "--after", helper,
                "--after", "cleanup", "--after", str(repo), "--", "bash", helper, "run", str(prompt), "502",
                "owner/repo", str(repo), "test/model", "enrichment-fixture"],
                 cwd=repo, env=env, capture_output=True, text=True, timeout=110)
            log_path = root / "pulse.log"
            log = log_path.read_text() if log_path.exists() else ""
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            with sqlite3.connect(env["WORKTREE_REGISTRY_DB"]) as db:
                records = [json.loads(row[0]) for row in db.execute("SELECT record FROM worktree_managed_lifetimes")]
            records = [r for r in records if "enrichment-fixture" in r["identity"]["path"]]
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["state"], "sealed")
            self.assertTrue(records[0]["launches"])
            self.assertTrue(all(launch.get("completion_evidence") == "systemd-cgroup-v1"
                                for launch in records[0]["launches"]))
            self.assertFalse(Path(records[0]["identity"]["path"]).exists(), (root / "pulse.log").read_text())

    def test_macos_probe_never_invokes_systemd(self):
        with patch.object(sys, "platform", "darwin"), patch.object(runner.subprocess, "check_output") as call:
            self.assertFalse(runner.backend_available())
            call.assert_not_called()

    def test_unavailable_user_manager_selects_legacy_before_creation(self):
        with patch.object(sys, "platform", "linux"), patch.object(Path, "is_file", return_value=True), \
                patch.object(runner.shutil, "which", return_value="/fixture/tool"), \
                patch.object(runner.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "systemctl")):
            self.assertFalse(runner.backend_available())

    def test_nonterminal_service_never_inherits_tool_output_pipes(self):
        with patch.object(sys.stdin, "isatty", return_value=False), runner.isolated_service_io() as (stdio, _, mode):
            self.assertEqual(mode, "--pipe")
            self.assertEqual(stdio["stdin"], subprocess.DEVNULL)
            for key in ("stdout", "stderr"):
                self.assertTrue(stat.S_ISREG(os.fstat(stdio[key].fileno()).st_mode))

    def test_backend_requires_supported_version_on_session_bus(self):
        for version, help_text, expected in (("249", "--expand-environment", False),
                                             ("250", "--expand-environment", True),
                                             ("259.1", "--expand-environment", True),
                                             ("250", "older CLI", False), (None, "", False)):
            with self.subTest(version=version), patch.object(sys, "platform", "linux"), \
                    patch.object(Path, "is_file", return_value=True), \
                    patch.object(runner.shutil, "which", return_value="/fixture/tool"), \
                    patch.object(runner.subprocess, "check_output", side_effect=[json.dumps({"data": version}), help_text]) as call:
                self.assertEqual(runner.backend_available(), expected)
                self.assertEqual(call.call_args_list[0].args[0][0], "busctl")

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

    def test_native_service_preserves_caller_umask(self):
        if not runner.backend_available():
            self.skipTest("rootless user-systemd unavailable")
        for mask in (0o022, 0o077, 0o002):
            with self.subTest(mask=oct(mask)), tempfile.TemporaryDirectory() as directory:
                environment = dict(os.environ, HOME=directory,
                                   AIDEVOPS_LIFECYCLE_STATE_DIR=directory + "/state")
                result = subprocess.run(  # nosec B603 # fixed interpreter and umask probe
                    [sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                     "--timeout-seconds", "20", "--", sys.executable, "-c",
                     "import os; print(oct(os.umask(0o077)))"],
                    cwd=directory, env=environment, umask=mask,
                    capture_output=True, text=True, timeout=30, check=True)
                self.assertEqual(result.stdout.strip(), oct(mask))


if __name__ == "__main__":
    unittest.main()
