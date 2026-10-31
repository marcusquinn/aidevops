#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Isolated/mocked acceptance coverage; never contact SSH or a running Tabby."""

import argparse
import contextlib
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tabby_session_config as config
import tabby_session_launch as launch
import tabby_session_legacy as legacy
import tabby_session_protocol as protocol
import tabby_session_remote as remote
import tabby_session_state as state
import tabby_session_terminal as terminal
import tabby_session_transport as transport
import tabby_sessions as app


def host(name="alpha", **kwargs):
    return config.validate_host(dict(id=name, sshHost="dev-" + name, **kwargs), 0)


def session(name="oc-001", sid="$1"):
    return dict(name=name, sid=sid, created="100", server="200")


class ConfigTests(unittest.TestCase):
    def test_reject_injection_and_unknown_fields(self):
        for value in ("-oProxyCommand=anything", "alpha;true", "alpha beta", "user@alpha", "alpha\n"):
            with self.subTest(value=value), self.assertRaises(config.SessionError):
                config.validate_host(dict(id="alpha", sshHost=value), 0)
        with self.assertRaises(config.SessionError):
            host(sshOptions=["anything"])
        with self.assertRaises(config.SessionError):
            host(sessionPrefix="oc.")
        with self.assertRaises(config.SessionError):
            host(identityFile="relative-identity")

    def test_config_order_disabled_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hosts.json"
            path.write_text(json.dumps(dict(version=1, hosts=[
                dict(id="beta", sshHost="dev-beta", restoreOrder=20),
                dict(id="alpha", sshHost="dev-alpha", restoreOrder=10),
                dict(id="off", sshHost="dev-off", enabled=False)])))
            self.assertEqual([h["id"] for h in config.load_hosts(path)], ["alpha", "beta"])
            with self.assertRaises(config.SessionError):
                config.load_hosts(path, "off")
            path.write_text(json.dumps(dict(version=1, hosts=[dict(id="a", sshHost="a")] * 2)))
            with self.assertRaises(config.SessionError):
                config.load_hosts(path)

    def test_equivalent_aliases_and_private_output(self):
        result = subprocess.CompletedProcess([], 0, "hostname generic.invalid\nuser generic\nport 22\n", "")
        with mock.patch.object(config.subprocess, "run", return_value=result):
            self.assertEqual(config.endpoint(host()), config.endpoint(host("beta")))
        with mock.patch.object(config, "endpoint", side_effect=[config.SessionError("unavailable"), "same"]):
            self.assertEqual(config.equivalent_aliases([host(), host("beta")], host("beta"), "same"), {"dev-beta"})

    def test_explicit_identity_and_argv(self):
        with self.assertRaisesRegex(config.SessionError, "identity file"):
            config.endpoint(host(identityFile="/nonexistent/generic-identity"))
        args = config.ssh_argv(host(port=2222, user="generic"))
        self.assertIn("BatchMode=yes", args)
        self.assertNotIn("StrictHostKeyChecking=no", args)
        self.assertEqual(args[-4:], ["-p", "2222", "-l", "generic"])

    def test_tabby_version_and_command_array_diagnostics(self):
        for version, help_output, succeeds in (("1.0.235", "--command", False),
                                               ("1.0.236", "--command [array]", True),
                                               ("1.0.236", "unknown", False)):
            responses = [subprocess.CompletedProcess([], 0, version, ""),
                         subprocess.CompletedProcess([], 0, help_output, "")]
            with mock.patch.object(config.subprocess, "run", side_effect=responses):
                if succeeds:
                    self.assertEqual(launch.check_tabby("generic-tabby"), version)
                else:
                    with self.assertRaises(config.SessionError):
                        launch.check_tabby("generic-tabby")


class ProtocolTests(unittest.TestCase):
    def test_real_posix_frame_preserves_payload_and_exit_codes(self):
        payload = "S\t$1\t100\t200\toc-001\n"
        for rc in (0, 75, 127):
            begin, end, script = protocol.framed_command(
                "printf '%s' " + shlex.quote(payload) + "\nexit " + str(rc))
            result = subprocess.run(  # nosec B603 - fixed local shell and generated fixture script, no SSH
                ["/bin/sh", "-c", script], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, rc)
            output = "generic startup line\n" * 12 + result.stdout + "generic shutdown line\n"
            self.assertEqual(protocol.extract_response(output, begin, end), payload)

    def test_missing_duplicate_reordered_markers_fail_closed(self):
        begin, end, _script = protocol.framed_command("exit 0")
        for output in ("generic noise\n", begin, end, begin + begin + end,
                       begin + end + end, end + begin):
            with self.subTest(output_length=len(output)), self.assertRaises(config.SessionError) as error:
                protocol.extract_response(output, begin, end)
            self.assertNotIn("generic noise", str(error.exception))

    def test_remote_transport_ignores_only_outside_frame_noise(self):
        run = subprocess.run

        def local_transport(argv, **kwargs):
            # Execute the generated POSIX command locally, never invoke SSH.
            result = run(shlex.split(argv[-1]), **kwargs)
            result.stdout = "generic startup line\n" * 12 + result.stdout + "generic shutdown\n"
            return result

        for payload in ("", "S\t$1\t100\t200\toc-001\n", "$1\n"):
            with mock.patch.object(remote.subprocess, "run", side_effect=local_transport):
                self.assertEqual(remote.remote(host(), "printf '%s' " + shlex.quote(payload)), payload)
        with mock.patch.object(remote.subprocess, "run", side_effect=local_transport):
            with self.assertRaises(remote.CreationCollision):
                remote.remote(host(), "exit 75")

    def test_unframed_collision_is_not_retryable(self):
        with mock.patch.object(remote.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 75, "generic startup output\n", "")):
            with self.assertRaisesRegex(config.SessionError, "boundaries missing"):
                remote.remote(host(), "exit 75")


class RemoteTests(unittest.TestCase):
    def test_inventory_natural_order_stable_ids_and_exclusion(self):
        data = "\n".join("S|${}|100|200|{}".format(i, name) for i, name in enumerate(
            ["oc-10", "worker-1", "oc-zeta", "oc-2", "oc-alpha"])) + "\nC|42|$0\n"
        with mock.patch.object(remote, "remote", return_value=data):
            sessions, clients = remote.inventory(host())
        self.assertEqual([s["name"] for s in sessions], ["oc-2", "oc-10", "oc-alpha", "oc-zeta"])
        self.assertEqual(clients, {("42", "$0")})

    def test_unsafe_name_rejected(self):
        for name in ("oc-;bad", "oc-001|extra"):
            with mock.patch.object(remote, "remote", return_value="S|$1|100|200|" + name + "\n"):
                with self.assertRaises(config.SessionError):
                    remote.inventory(host())

    def test_delimiter_in_unrelated_name_is_excluded_without_truncation(self):
        with mock.patch.object(remote, "remote", return_value="S|$1|100|200|worker|extra\n"):
            self.assertEqual(remote.inventory(host()), ([], set()))

    def test_unexpected_inside_frame_record_still_rejected(self):
        with mock.patch.object(remote, "remote", return_value="generic unexpected record\n"):
            with self.assertRaisesRegex(config.SessionError, "Unexpected tmux inventory"):
                remote.inventory(host())

    def test_creation_collision_reenumerates_not_reuses(self):
        initial = [session("oc-001"), session("oc-009", "$9")]
        collision = initial + [session("oc-010", "$10")]
        final = collision + [session("oc-011", "$11")]
        with mock.patch.object(remote, "inventory", side_effect=[(initial, set()),
                            (collision, set()), (final, set())]), mock.patch.object(remote, "remote",
                            side_effect=[remote.CreationCollision("collision"), "$11\n"]) as call:
            created, _clients = remote.create(host())
        self.assertEqual(created["name"], "oc-011")
        self.assertIn("new-session -d -s oc-010", call.call_args_list[0].args[1])
        self.assertIn("new-session -d -s oc-011", call.call_args_list[1].args[1])

    def test_creation_empty_and_retained_on_refresh_failure(self):
        with mock.patch.object(remote, "inventory", side_effect=[([], set()), config.SessionError("offline")]), mock.patch.object(
                remote, "remote", return_value="$1\n"):
            with self.assertRaisesRegex(config.SessionError, "Created oc-001"):
                remote.create(host())

    def test_ambiguous_creation_failure_does_not_allocate_another_session(self):
        with mock.patch.object(remote, "inventory", return_value=([], set())), mock.patch.object(
                remote, "remote", side_effect=config.SessionError("SSH timeout")) as call:
            with self.assertRaisesRegex(config.SessionError, "uncertain for oc-001"):
                remote.create(host())
        self.assertEqual(call.call_count, 1)

    def test_remote_errors_not_empty_or_auth_logs(self):
        for rc, expected in ((127, "tmux"), (255, "SSH/tmux")):
            with mock.patch.object(remote.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], rc, "", "private diagnostic must not escape")):
                with self.assertRaisesRegex(config.SessionError, expected) as error:
                    remote.inventory(host())
                self.assertNotIn("private diagnostic", str(error.exception))

    def test_attach_remote_shell_argv_is_quoted(self):
        args = remote.attach_command(host(), session(), "AIDEVOPS_GENERIC:")
        outer = shlex.split(args[-1])
        self.assertEqual(outer[:2], ["sh", "-c"])
        command = shlex.split(outer[2].split("\n", 1)[1])
        self.assertEqual(command[:6], ["exec", "tmux", "if-shell", "-F", "-t", "$1"])
        self.assertEqual(command[6], "#{&&:#{&&:#{==:#{session_created},100},#{==:#{pid},200}},#{m:oc-*,#{session_name}}}")
        self.assertEqual(command[7], "attach-session -t '$1'")
        self.assertIn("no replacement attached", command[8])
        self.assertNotIn("kill", outer[2])


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = state.state_directory(Path(self.temp.name).resolve())
        self.key = state.state_key("endpoint", session())

    def tearDown(self):
        os.close(self.directory)
        self.temp.cleanup()

    def test_pending_expiry_and_outdated_confirmation(self):
        with state.lease(self.directory, self.key) as handle:
            self.assertEqual(handle.observe(set(), "$1"), "missing")
            old = handle.reserve()
        with state.lease(self.directory, self.key) as handle:
            self.assertEqual(handle.observe(set(), "$1"), "pending")
            value = handle.read()
            value["expires"] = 0
            handle.write(value)
        with state.lease(self.directory, self.key) as handle:
            self.assertFalse(handle.claim(old))
            fresh = handle.reserve()
        with state.lease(self.directory, self.key) as handle:
            self.assertFalse(handle.claim(old))
            self.assertTrue(handle.claim(fresh))

    def test_corrupt_unlocked_state_fails_closed(self):
        for payload in (b'{"phase":', b'[]', b'{"token":false}', b'{"expires":true}'):
            with self.subTest(payload=payload):
                with state.lease(self.directory, self.key) as active:
                    self.assertTrue(active.acquire())
                    os.lseek(active.fd, 0, os.SEEK_SET)
                    os.write(active.fd, payload)
                    os.ftruncate(active.fd, len(payload))
                    with state.lease(self.directory, self.key) as busy:
                        self.assertEqual(busy.observe(set(), "$1"), "pending")
                with state.lease(self.directory, self.key) as observer:
                    with self.assertRaisesRegex(config.SessionError, "Unreadable attachment state"):
                        observer.observe(set(), "$1")
                    os.lseek(observer.fd, 0, os.SEEK_SET)
                    self.assertEqual(os.read(observer.fd, 8192), payload)

    def test_connected_requires_remote_client_evidence_and_disconnect_recovers(self):
        with state.lease(self.directory, self.key) as active:
            active.acquire()
            active.write(dict(phase="attaching", remote_pid="42"))
            with state.lease(self.directory, self.key) as other:
                self.assertEqual(other.observe(set(), "$1"), "pending")
                self.assertEqual(other.observe({("42", "$1")}, "$1"), "connected")
        with state.lease(self.directory, self.key) as reopened:
            self.assertEqual(reopened.observe(set(), "$1"), "missing")

    def test_rename_and_independent_client_account_state(self):
        self.assertEqual(self.key, state.state_key("endpoint", session("oc-renamed")))
        self.assertNotEqual(self.key, state.state_key("another-endpoint", session()))
        with tempfile.TemporaryDirectory() as laptop:
            other = state.state_directory(Path(laptop).resolve())
            try:
                with state.lease(self.directory, self.key) as left, state.lease(other, self.key) as right:
                    self.assertTrue(left.acquire())
                    self.assertTrue(right.acquire())
            finally:
                os.close(other)

    def test_symlink_hardlink_and_permissions_fail_closed(self):
        target = Path(self.temp.name) / "target"
        target.touch(mode=0o600)
        link = Path(self.temp.name) / (self.key + ".lock")
        link.symlink_to(target)
        with self.assertRaises(OSError):
            state.Lease(self.directory, self.key)
        link.unlink()
        os.link(target, link)
        with self.assertRaises(config.SessionError):
            state.Lease(self.directory, self.key)
        parent_link = Path(self.temp.name) / "symlink-dir"
        parent_link.symlink_to(self.temp.name, target_is_directory=True)
        with self.assertRaises(OSError):
            state.state_directory(parent_link / "nested")

    def test_lease_inherited_by_owned_child(self):
        with state.lease(self.directory, self.key) as active:
            active.acquire()
            child = subprocess.Popen(  # nosec B603 - current interpreter and fixed isolated child script
                                     [sys.executable, "-c", "import sys; sys.stdin.read()"],
                                     stdin=subprocess.PIPE, pass_fds=(active.fd,))
        try:
            with state.lease(self.directory, self.key) as observer:
                self.assertFalse(observer.acquire())
        finally:
            child.communicate()
        with state.lease(self.directory, self.key) as observer:
            self.assertTrue(observer.acquire())

    def test_orphaned_transport_uses_nonce_not_pid_and_recovers(self):
        with state.lease(self.directory, self.key) as handle:
            handle.acquire()
            handle.write(dict(phase="attaching", token="a" * 48, remote_pid="42"))
        with mock.patch.object(state, "local_managed", return_value=True), state.lease(self.directory, self.key) as handle:
            self.assertEqual(handle.observe({("42", "$1")}, "$1"), "connected")
        with mock.patch.object(state, "local_managed", return_value=False), state.lease(self.directory, self.key) as handle:
            self.assertEqual(handle.observe(set(), "$1"), "missing")


class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tabby space ; ")
        self.inventory_path = str(Path(self.temp.name).resolve() / "hosts ; safe.json")
        self.state_path = str(Path(self.temp.name).resolve() / "state space")
        Path(self.inventory_path).write_text(json.dumps(dict(version=1, hosts=[
            dict(id="alpha", sshHost="dev-alpha", connectIntervalSeconds=0),
            dict(id="beta", sshHost="dev-beta", connectIntervalSeconds=0)])))

    def tearDown(self):
        self.temp.cleanup()

    def context(self, binary="tabby"):
        args = argparse.Namespace(config=self.inventory_path, state_dir=self.state_path)
        return launch.LaunchContext(args, binary, host(), "endpoint", set(), [session()])

    def test_transport_argv_spaces_and_metacharacters(self):
        args = launch.launch_argv(self.context("tabby space"), session(), "key", "nonce")
        self.assertIn("--command=" + self.inventory_path, args)
        self.assertIn("--command=" + self.state_path, args)
        self.assertEqual(args[:2], ["tabby space", "run"])

    def test_concurrent_requests_and_repeat_restore(self):
        def request_one(_number):
            return launch.request(self.context(), session(), set())
        with mock.patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), contextlib.redirect_stdout(io.StringIO()):
            with ThreadPoolExecutor(max_workers=8) as pool:
                outcomes = list(pool.map(request_one, range(16)))
        self.assertEqual(outcomes.count("requested"), 1)
        self.assertEqual(outcomes.count("pending"), 15)

    def test_launch_failure_preserves_session_and_bounded_pending(self):
        with mock.patch.object(launch.subprocess, "run", side_effect=subprocess.TimeoutExpired("tabby", 20)), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launch.request(self.context(), session(), set()), "failed")
        self.assertEqual(app.observe(self.state_path, state.state_key("endpoint", session()), set(), "$1"), "pending")

    def run_main(self, args, inventory_effect):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            for name, value in (("endpoint", "endpoint"), ("equivalent_aliases", {"dev-alpha", "dev-beta"}),
                                ("local_legacy", set()), ("tabby_executable", "tabby"), ("check_tabby", "1.0.236")):
                stack.enter_context(mock.patch.object(app, name, return_value=value))
            stack.enter_context(mock.patch.object(app, "inventory", side_effect=inventory_effect))
            stack.enter_context(mock.patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(errors))
            result = app.main(args + ["--config", self.inventory_path, "--state-dir", self.state_path])
        return result, output.getvalue(), errors.getvalue()

    def test_restore_continues_after_host_failure_accurate_aggregate(self):
        result, output, errors = self.run_main(["restore"], [config.SessionError("offline"), ([session()], set())])
        self.assertEqual(result, 1)
        self.assertIn("alpha\tfailed", errors)
        self.assertIn("beta\toc-001\trequested", output)
        self.assertIn("requested=1 skipped=0 failed=1", output)

    def test_dry_run_and_list_create_no_reservations(self):
        for args in (["restore", "--dry-run"], ["new", "alpha", "--dry-run"], ["list"]):
            result, _output, _errors = self.run_main(args, [([session()], set())] * 2)
            self.assertEqual(result, 0)
            self.assertFalse(Path(self.state_path).exists())

    def test_partial_host_failure_keeps_already_requested_count(self):
        def action(_args, selected, _hosts, _binary):
            yield "requested"
            if selected["id"] == "alpha":
                raise config.SessionError("offline after first request")
        with mock.patch.object(app, "host_action", side_effect=action):
            result, output, _errors = self.run_main(["restore"], [])
        self.assertEqual(result, 1)
        self.assertIn("requested=2 skipped=0 failed=1", output)

    def test_doctor_does_not_probe_remote_implicitly_or_initialize_state(self):
        result, output, _errors = self.run_main(["doctor"], [])
        self.assertEqual(result, 0)
        self.assertIn("Remote probes: not requested", output)
        self.assertFalse(Path(self.state_path).exists())

    def test_old_launch_id_does_not_attach(self):
        identity = session()
        key = state.state_key("endpoint", identity)
        directory = state.state_directory(self.state_path)
        try:
            with state.lease(directory, key) as handle:
                handle.acquire()
                handle.reserve()
        finally:
            os.close(directory)
        args = app.parser().parse_args(["_attach", "alpha", "--key", key, "--token", "outdated",
                                       "--identity", "$1:100:200", "--state-dir", self.state_path])
        with mock.patch.object(transport, "endpoint", return_value="endpoint"), mock.patch.object(transport, "attach_held") as connect:
            with self.assertRaises(config.SessionError):
                app.attach(args, host(), [host()])
            connect.assert_not_called()


class LegacyAndRelayTests(unittest.TestCase):
    def test_managed_nonce_exact_match_and_process_scope(self):
        nonce = "a" * 48
        text = "ssh -tt dev-alpha sh -c printf AIDEVOPS_TABBY_" + nonce + ":\n"
        with mock.patch.object(legacy, "local_processes", return_value=text):
            self.assertTrue(legacy.local_managed(nonce))
            self.assertFalse(legacy.local_managed("b" * 48))
            self.assertFalse(legacy.local_managed("a"))

    def test_supported_legacy_and_rename_ambiguity(self):
        data = "ssh -o ConnectTimeout=15 -t dev-alpha tmux attach-session -t oc-001\n"
        data += "ssh -tt dev-beta 'tmux attach -t oc-002'\n"
        data += "ssh unrelated tmux attach -t oc-003\n"
        targets = legacy.legacy_targets(data, {"dev-alpha", "dev-beta"})
        self.assertEqual(targets, {"oc-001", "oc-002"})
        self.assertEqual(legacy.legacy_state(targets, session(), [session()]), "legacy")
        self.assertEqual(legacy.legacy_state({"oc-old"}, session(), [session()]), "legacy-ambiguous")

    def test_protocol_marker_stripped_without_losing_titles_or_terminal_bytes(self):
        marker = "AIDEVOPS_GENERIC:"
        payload = b"banner\r\n" + marker.encode() + b"42\r\n\x1b]0;A001 title\x07prompt> "
        read_fd, write_fd = os.pipe()
        os.write(write_fd, payload)
        os.close(write_fd)
        output, pids = io.BytesIO(), []
        with os.fdopen(read_fd, "rb") as stream:
            terminal.relay_output(stream, marker, pids.append, output)
        self.assertEqual(pids, ["42"])
        self.assertEqual(output.getvalue(), b"banner\r\n\x1b]0;A001 title\x07prompt> ")


if __name__ == "__main__":
    unittest.main()
