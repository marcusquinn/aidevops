#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Managed runner capability, startup and output-transport contracts."""

import importlib.util
import json
import os
from pathlib import Path
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
import worktree_lifetime_owner as owner

SPEC = importlib.util.spec_from_file_location("managed_run", SCRIPTS / "worktree-managed-run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerControlTests(unittest.TestCase):
    def test_native_enrichment_exec_preserves_managed_admission(self):
        if not runner.backend_available():
            self.skipTest("rootless user-systemd unavailable")
        with tempfile.TemporaryDirectory(prefix="enrichment-managed-") as directory:
            root = Path(directory)
            repo, remote = root / "repo", root / "remote.git"
            env = dict(os.environ, HOME=str(root), AIDEVOPS_WORKTREE_BASE_DIR=str(root / "trees"),
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
                subprocess.run(["git", *args], env=env, capture_output=True, check=True, timeout=15)
            runtime = root / "runtime.sh"
            runtime.write_text('#!/usr/bin/env bash\nset -euo pipefail\n'
                f'source "{SCRIPTS}/shared-constants.sh"\n'
                'branch=$(git -C "$WORKER_WORKTREE_PATH" symbolic-ref --short HEAD)\n'
                'claim_worktree_ownership "$WORKER_WORKTREE_PATH" "$branch" '
                '--owner-pid "$$" --session fixture-enrichment --task 502\n')
            runtime.chmod(0o700)
            env["HEADLESS_RUNTIME_HELPER"] = str(runtime)
            prompt = root / "prompt"
            prompt.write_text("fixture, no model or GitHub access")
            helper = str(SCRIPTS / "pulse-enrichment-run-helper.sh")
            result = subprocess.run([sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                "--timeout-seconds", "90", "--after", "bash", "--after", helper,
                "--after", "cleanup", "--after", str(repo), "--", "bash", helper, "run", str(prompt), "502",
                "owner/repo", str(repo), "test/model", "enrichment-fixture"],
                env=env, capture_output=True, text=True, timeout=110)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
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
            with self.subTest(mask=oct(mask)):
                result = subprocess.run(
                    [sys.executable, str(SCRIPTS / "worktree-managed-run.py"),
                     "--timeout-seconds", "20", "--", sys.executable, "-c",
                     "import os; print(oct(os.umask(0o077)))"],
                    umask=mask, capture_output=True, text=True, timeout=30, check=True)
                self.assertEqual(result.stdout.strip(), oct(mask))


if __name__ == "__main__":
    unittest.main()
