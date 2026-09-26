#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused service lifecycle contracts; no real managers, databases or accounts."""

import argparse
from contextlib import redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SPEC = importlib.util.spec_from_file_location(
    "opencode_service", Path(__file__).resolve().parents[1] / "opencode-service-helper.py")
sys.path.insert(0, str(Path(SPEC.origin).parent))
import opencode_service_lifecycle as lifecycle_module
import opencode_service_state as state_module

service_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(service_module)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", Path.home() / ".aidevops/.agent-workspace/tmp"))
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.service = service_module.Service(self.home, "darwin")
        self.args = argparse.Namespace(port=None, shard=None, route_new=False, fresh_default=False)
        self.data = {"schema": state_module.SCHEMA, "port": 49036, "shard": "managed-default",
                     "directory": str(self.home), "enabled": True, "route_new": False,
                     "python": "/usr/bin/python3", "opencode": "/usr/local/bin/opencode", "path": "/usr/bin"}
        helper = self.home / ".aidevops/agents/scripts/opencode-service-helper.py"
        helper.parent.mkdir(parents=True)
        helper.write_text("# helper fixture\n")
        helper.with_name("opencode-launcher-helper.sh").write_text("# launcher fixture\n")
        for name in ("opencode_service_state.py", "opencode_service_lifecycle.py"):
            helper.with_name(name).write_text("# module fixture\n")
        self.helper_patch = patch.object(lifecycle_module, "HELPER", helper)
        self.helper_patch.start()
        self.addCleanup(self.helper_patch.stop)
        self.command_patch = patch.object(lifecycle_module, "command", return_value=argparse.Namespace(returncode=1, stdout=""))
        self.command_mock = self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        state_command = patch.object(state_module, "command", self.command_mock)
        state_command.start()
        self.addCleanup(state_command.stop)

    def install(self):
        with patch.object(self.service, "supported"), patch.object(self.service, "pid", return_value=0), \
             patch.object(self.service, "listeners", return_value=set()), \
             patch.object(self.service, "start") as start, \
             patch.object(lifecycle_module.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"):
            result = self.service.install(self.args)
        return result, start

    def test_launchd_definition_roundtrips_special_paths(self):
        self.data["path"] = '/path with space/"<&%$:/bin'
        definition = plistlib.loads(self.service.definition_bytes(self.data))
        self.assertEqual(definition["EnvironmentVariables"]["PATH"], self.data["path"])
        self.assertEqual(definition["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(definition["Umask"], 0o077)
        self.assertNotIn("--pure", definition["ProgramArguments"])
        self.assertEqual(definition["ProgramArguments"][1], str(self.service.runtime / "opencode-service-helper.py"))

    def desktop_fixture(self, capabilities=None):
        binary = self.home / "Desktop.app/Contents/MacOS/OpenCode"
        binary.parent.mkdir(parents=True)
        binary.write_text("fixture")
        manifest = binary.parent.parent / "Resources/capabilities.json"
        if capabilities is not None:
            manifest.parent.mkdir()
            manifest.write_text(json.dumps(capabilities))
        directory = self.home / "repo with spaces & 项目"
        directory.mkdir()
        return argparse.Namespace(desktop_binary=str(binary), dir=str(directory), dry_run=True), manifest

    def test_desktop_link_preview_preserves_directory_without_starting_service(self):
        args, _ = self.desktop_fixture({"connect-project": 1})
        with patch.object(self.service, "start") as start:
            link = service_module.desktop_link(self.service, self.data, args)
        start.assert_not_called()
        self.assertEqual(urlsplit(link).netloc, "connect")
        self.assertEqual(parse_qs(urlsplit(link).query),
                         {"url": ["http://127.0.0.1:49036"], "directory": [args.dir]})
        self.assertFalse(self.service.config.exists())

    def test_desktop_link_rejects_missing_or_unknown_capability_before_start(self):
        args, manifest = self.desktop_fixture()
        with patch.object(self.service, "start") as start:
            args.dry_run = False
            with self.assertRaisesRegex(RuntimeError, "select the server manually"):
                service_module.desktop_link(self.service, self.data, args)
            manifest.parent.mkdir()
            for capabilities in ({"connect-project": 2}, {"connect-project": True}, [], {}):
                manifest.write_text(json.dumps(capabilities))
                with self.assertRaisesRegex(RuntimeError, "select the server manually"):
                    service_module.desktop_link(self.service, self.data, args)
        start.assert_not_called()

    def test_desktop_link_does_not_enable_a_disabled_owner(self):
        args, _ = self.desktop_fixture({"connect-project": 1})
        with patch.object(self.service, "start") as start:
            with self.assertRaisesRegex(RuntimeError, "disabled"):
                service_module.desktop_link(self.service, dict(self.data, enabled=False), args)
            args.dry_run = False
            self.service.save(dict(self.data, enabled=False))
            with self.assertRaisesRegex(RuntimeError, "disabled"):
                service_module.desktop_link(self.service, self.data, args)
        start.assert_not_called()

    def test_desktop_link_waits_for_owner_before_returning_request(self):
        args, _ = self.desktop_fixture({"connect-project": 1})
        args.dry_run = False
        self.service.save(self.data)
        with patch.object(self.service, "start") as start:
            self.assertTrue(service_module.desktop_link(self.service, self.data, args).startswith("opencode://connect?"))
        start.assert_called_once_with(self.data)
        with patch.object(self.service, "start", side_effect=RuntimeError("not ready")):
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                service_module.desktop_link(self.service, self.data, args)

    def test_desktop_link_rejects_invalid_directory_before_start(self):
        args, _ = self.desktop_fixture({"connect-project": 1})
        args.dir = str(self.home / "missing")
        with patch.object(self.service, "start") as start:
            with self.assertRaisesRegex(RuntimeError, "directory must exist"):
                service_module.desktop_link(self.service, self.data, args)
        start.assert_not_called()

    def test_desktop_wrapper_dry_run_passes_encoded_link_without_launching(self):
        args, _ = self.desktop_fixture({"connect-project": 1})
        Path(args.desktop_binary).chmod(0o700)
        self.service.save(self.data)
        tools = self.home / "bin"
        tools.mkdir()
        uname = tools / "uname"
        uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n")
        uname.chmod(0o700)
        work = self.home / "launcher-work"
        env = dict(os.environ, HOME=str(self.home), AIDEVOPS_WORK_DIR=str(work),
                   PATH=str(tools) + os.pathsep + os.environ["PATH"])
        for key in ("OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME"):
            env.pop(key, None)
        command = ["bash", str(Path(SPEC.origin).with_name("opencode-launcher-helper.sh")), "desktop",
                   "--connect-managed", "--dir", args.dir, "--source-binary", args.desktop_binary, "--dry-run"]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("opencode://connect", result.stdout)
        self.assertIn("%26", result.stdout)
        self.assertNotIn("--connect-managed", result.stdout)
        self.assertFalse(work.exists())

    def test_systemd_escaping_has_no_environment_dollar_expansion(self):
        self.service.platform = "linux"
        self.data["path"] = '/space %n/$HOME/"quote"'
        definition = self.service.definition_bytes(self.data).decode()
        self.assertIn('%%n/$HOME/\\"quote\\"', definition)
        self.assertNotIn('$$HOME', definition)
        self.assertIn("Restart=on-failure", definition)
        self.assertEqual(state_module.systemd_quote("$HOME", True), '"$$HOME"')
        with self.assertRaises(RuntimeError):
            state_module.systemd_quote("bad\nunit")

    def test_native_windows_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Native Windows"):
            service_module.Service(self.home, "win32").supported()

    def test_install_dry_run_and_inherited_auth_fail_before_mutation(self):
        with patch.object(service_module.sys, "argv", ["helper", "install", "--dry-run"]), \
             redirect_stderr(io.StringIO()), patch.object(service_module, "Service") as constructor:
            with self.assertRaises(SystemExit):
                service_module.main()
            constructor.assert_not_called()
        with patch.object(service_module.sys, "argv", ["helper", "install"]), \
             patch.dict(os.environ, {"OPENCODE_SERVER_USERNAME": "fixture"}), \
             patch.object(service_module, "Service") as constructor:
            with self.assertRaisesRegex(RuntimeError, "Authenticated server mode"):
                service_module.main()
            constructor.assert_not_called()

    def test_linux_without_user_manager_is_rejected(self):
        service = service_module.Service(self.home, "linux")
        with patch.object(state_module.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "systemd --user"):
                service.supported()

    def test_existing_disabled_install_stays_disabled(self):
        self.data["enabled"] = False
        self.service.save(self.data)
        data, start = self.install()
        self.assertFalse(data["enabled"])
        start.assert_not_called()

    def test_idempotent_install_preserves_definition_and_routing(self):
        first, _ = self.install()
        inode = self.service.definition.stat().st_ino
        second, _ = self.install()
        self.assertEqual(first, second)
        self.assertFalse(second["route_new"])
        self.assertEqual(inode, self.service.definition.stat().st_ino)
        self.assertEqual(self.service.config.stat().st_mode & 0o777, 0o600)

    def test_routing_requires_explicit_opt_in(self):
        self.args.route_new = True
        data, _ = self.install()
        self.assertTrue(data["route_new"])

    def test_reinstall_refreshes_executables_without_changing_identity_or_opt_out(self):
        self.service.save(dict(self.data, enabled=False, python="/obsolete/python3",
                               opencode="/obsolete/opencode", path="/obsolete"))
        data, start = self.install()
        self.assertEqual(data["python"], "/usr/bin/python3")
        self.assertEqual(data["opencode"], "/usr/bin/opencode")
        self.assertNotIn("/obsolete", data["path"])
        self.assertEqual(data["shard"], self.data["shard"])
        self.assertEqual(data["port"], self.data["port"])
        self.assertFalse(data["enabled"])
        start.assert_not_called()

    def test_setup_routes_only_a_fresh_history_free_install(self):
        self.args.fresh_default = True
        with patch.object(self.service, "existing_history", return_value=False):
            data, _ = self.install()
        self.assertTrue(data["route_new"])
        self.service.save(dict(data, route_new=False))
        data, _ = self.install()
        self.assertFalse(data["route_new"], "Updates must not override routing choice")

    def test_existing_history_is_retained_without_inspecting_sqlite(self):
        database = self.service.work / "opencode-interactive/project-old/opencode/opencode.db"
        state_module.atomic_write(database, b"untouched old history")
        self.args.fresh_default = True
        data, _ = self.install()
        self.assertFalse(data["route_new"])
        self.assertEqual(database.read_bytes(), b"untouched old history")

    def test_invalid_identity_fails_before_writes(self):
        for port, shard in ((0, None), (65536, None), (49036, "../old")):
            self.args.port, self.args.shard = port, shard
            with self.assertRaises(RuntimeError):
                self.install()
            self.assertFalse(self.service.config.exists())
            self.assertFalse(self.service.definition.exists())

    def test_identity_cannot_change_on_update(self):
        self.service.save(self.data)
        self.args.port = 49037
        with self.assertRaisesRegex(RuntimeError, "identity is immutable"):
            self.install()
        self.assertEqual(self.service.load()["port"], 49036)

    def test_foreign_definition_is_not_replaced(self):
        state_module.atomic_write(self.service.definition, plistlib.dumps({"Label": "other"}))
        with self.assertRaisesRegex(RuntimeError, "not aidevops-managed"):
            self.install()
        self.assertFalse(self.service.config.exists())

    def test_worktree_service_is_rejected(self):
        with patch.object(lifecycle_module, "HELPER", self.home / "Git/worktree/helper.py"):
            with self.assertRaisesRegex(RuntimeError, "Deploy the helper first"):
                self.install()

    def test_runtime_survives_deployed_helper_disappearing(self):
        self.install()
        staged = self.service.runtime / "opencode-service-helper.py"
        expected = staged.read_bytes()
        lifecycle_module.HELPER.unlink()
        self.assertEqual(staged.read_bytes(), expected)
        self.assertTrue((self.service.runtime / "gh").stat().st_mode & 0o100)

    def test_staged_cli_imports_without_the_deployed_source(self):
        for name in lifecycle_module.RUNTIME_FILES:
            lifecycle_module.HELPER.with_name(name).write_bytes(Path(SPEC.origin).with_name(name).read_bytes())
        self.install()
        for name in lifecycle_module.RUNTIME_FILES:
            lifecycle_module.HELPER.with_name(name).unlink()
        result = subprocess.run(
            [sys.executable, str(self.service.runtime / "opencode-service-helper.py"), "route"],
            env=dict(os.environ, HOME=str(self.home)), text=True, capture_output=True, timeout=15, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "direct")

    def test_deployment_symlink_preserves_the_allowed_helper_identity(self):
        for name in lifecycle_module.RUNTIME_FILES:
            lifecycle_module.HELPER.with_name(name).write_bytes(Path(SPEC.origin).with_name(name).read_bytes())
        alias = lifecycle_module.HELPER.parent.parent
        bundle = self.home / "bundle"
        alias.rename(bundle)
        alias.symlink_to(bundle, target_is_directory=True)
        binary = self.home / "bin/systemctl"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o700)
        result = subprocess.run(
            [sys.executable, str(lifecycle_module.HELPER), "install"],
            env=dict(os.environ, HOME=str(self.home), PATH=str(binary.parent)),
            text=True, capture_output=True, timeout=15, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("opencode is required", result.stderr)
        self.assertFalse(self.service.config.exists(), "Missing prerequisites must stop before writes")

    def test_changed_running_definition_is_not_restarted(self):
        self.service.save(self.data)
        with patch.object(self.service, "supported"), patch.object(self.service, "pid", return_value=123), \
             patch.object(lifecycle_module.shutil, "which", return_value="/usr/bin/tool"):
            with self.assertRaisesRegex(RuntimeError, "stop the idle owner"):
                self.service.install(self.args)

    def test_real_launcher_routes_new_sessions_and_preserves_explicit_direct(self):
        self.service.save(dict(self.data, route_new=True))
        binary = self.home / "bin/opencode"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o700)
        environment = dict(os.environ, HOME=str(self.home), TERM_PROGRAM="fixture",
                           TABBY_CONFIG_DIRECTORY="", PATH=str(binary.parent) + ":" + os.environ["PATH"],
                           AIDEVOPS_TEMP_DIR=str(self.home / "tmp"))
        launcher = str(Path(SPEC.origin).with_name("opencode-launcher-helper.sh"))

        def invoke(*arguments):
            return subprocess.run(["/bin/bash", launcher, "--dir", str(self.home), "--dry-run", *arguments],
                                  env=environment, text=True, capture_output=True, timeout=15, check=False)

        managed = invoke()
        self.assertEqual(managed.returncode, 0, managed.stderr)
        self.assertIn("opencode attach http://127.0.0.1:49036", managed.stdout)
        direct = invoke("--direct")
        self.assertEqual(direct.returncode, 0, direct.stderr)
        self.assertIn("XDG_DATA_HOME=", direct.stdout)
        self.assertNotIn("opencode attach", direct.stdout)
        rejected = invoke("--", "--model", "fixture")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Managed routing rejects raw flags", rejected.stderr)

    def test_healthy_unknown_listener_is_rejected_before_http(self):
        lock = self.service.shard(self.data) / ".aidevops-server-owner/pid"
        state_module.atomic_write(lock, b"123\n")
        with patch.object(self.service, "pid", return_value=123), \
             patch.object(self.service, "listeners", return_value={456}), \
             patch.object(self.service, "descendant", return_value=False), \
             patch.object(state_module.urllib.request, "build_opener") as http:
            with self.assertRaisesRegex(RuntimeError, "not the managed owner"):
                self.service.health(self.data)
            http.assert_not_called()

    def test_failed_fresh_install_disables_restart_and_routing(self):
        with patch.object(self.service, "supported"), patch.object(self.service, "pid", return_value=0), \
             patch.object(self.service, "listeners", return_value=set()), \
             patch.object(self.service, "start", side_effect=RuntimeError("readiness failed")), \
             patch.object(self.service, "stop") as stop, \
             patch.object(lifecycle_module.shutil, "which", return_value="/usr/bin/tool"):
            with self.assertRaisesRegex(RuntimeError, "readiness failed"):
                self.service.install(self.args)
            stop.assert_called_once()
        self.assertFalse(self.service.load()["enabled"])
        self.assertFalse(self.service.load()["route_new"])

    def test_symlink_and_concurrent_lifecycle_are_refused(self):
        self.service.config.parent.mkdir(parents=True)
        self.service.config.symlink_to(self.home / "other")
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            self.service.save(self.data)
        with service_module.lifecycle_lock(self.service):
            with self.assertRaisesRegex(RuntimeError, "in progress"):
                with service_module.lifecycle_lock(self.service):
                    self.fail("Concurrent operation acquired the lock")

    def test_symlinked_parent_cannot_redirect_managed_writes(self):
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        (self.home / ".config").symlink_to(elsewhere)
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            self.service.save(self.data)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_loaded_inactive_launchd_job_requires_explicit_stop(self):
        self.command_mock.return_value.returncode = 0
        with self.assertRaisesRegex(RuntimeError, "job is loaded"):
            self.install()
        self.assertFalse(self.service.definition.exists())

    def test_linux_disable_removes_autostart_even_if_stop_fails(self):
        self.service.platform = "linux"
        with patch.object(self.service, "stop", side_effect=RuntimeError("stop failed")):
            with self.assertRaisesRegex(RuntimeError, "stop failed"):
                self.service.disable(self.data)
        self.command_mock.assert_called_with("systemctl", "--user", "disable", state_module.UNIT)
        self.assertFalse(self.service.load()["enabled"])

    def test_recover_dead_lock_never_touches_database(self):
        lock = self.service.shard(self.data) / ".aidevops-server-owner/pid"
        database = self.service.shard(self.data) / "opencode/opencode.db"
        state_module.atomic_write(lock, b"999999\n")
        state_module.atomic_write(database, b"history stays here")
        with patch.object(service_module.os, "kill", side_effect=ProcessLookupError):
            self.service.recover_dead_lock(self.data)
        self.assertFalse(lock.parent.exists())
        self.assertEqual(database.read_bytes(), b"history stays here")

    def test_recovery_refuses_live_pid_and_database_holders(self):
        lock = self.service.shard(self.data) / ".aidevops-server-owner/pid"
        state_module.atomic_write(lock, b"123\n")
        with patch.object(service_module.os, "kill"):
            with self.assertRaisesRegex(RuntimeError, "PID is alive"):
                self.service.recover_dead_lock(self.data)
        database = self.service.shard(self.data) / "opencode/opencode.db"
        state_module.atomic_write(database, b"history")
        self.command_mock.return_value.returncode = 0
        with patch.object(service_module.os, "kill", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(RuntimeError, "still has holders"):
                self.service.recover_dead_lock(self.data)
        self.assertTrue(lock.exists())


if __name__ == "__main__":
    unittest.main()
