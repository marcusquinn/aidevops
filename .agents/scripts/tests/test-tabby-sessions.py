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
import tabby_session_hosts as host_app
import tabby_host_files as host_files
import tabby_host_ssh_scan as ssh_scan


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

    def test_identity_selection_for_probes_and_interactive_connections(self):
        for probe in (True, False):
            for fields, expected in (({}, None), ({"identityFile": "/generic/key"}, "yes"),
                                     ({"identitiesOnly": True}, "yes"),
                                     ({"identityFile": "/generic/key", "identitiesOnly": False}, "no")):
                args = config.ssh_argv(host(**fields), probe=probe)
                options = [arg for arg in args if arg.startswith("IdentitiesOnly=")]
                self.assertEqual(options, [] if expected is None else ["IdentitiesOnly=" + expected])
                self.assertEqual("BatchMode=yes" in args, probe)
                self.assertEqual("-tt" in args, not probe)
        for value in ("yes", 1, None):
            with self.assertRaisesRegex(config.SessionError, "identitiesOnly must be boolean"):
                host(identitiesOnly=value)

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

    def test_inventory_recovers_from_connection_burst(self):
        run = subprocess.run
        payload = "".join("S|${}|100|200|oc-{:03d}\n".format(i, i) for i in range(1, 21))

        def recovered(argv, **kwargs):
            # Execute the actual framed response locally after transient failures.
            if failures:
                return failures.pop(0)
            return run(shlex.split(argv[-1]), **kwargs)

        failures = [subprocess.CompletedProcess([], 255, "", message) for message in (
            "kex_exchange_identification: read: Connection reset by peer",
            "mux_client_request_session: session request failed: Session open refused by peer")]
        with mock.patch.object(remote, "INVENTORY", "printf '%s' " + shlex.quote(payload)), mock.patch.object(
                remote.subprocess, "run", side_effect=recovered) as probe, mock.patch.object(
                remote.time, "sleep") as sleep:
            sessions, clients = remote.inventory(host())
            self.assertEqual(len(sessions), 20)
            self.assertEqual(clients, set())
            self.assertEqual(probe.call_count, 3)
            self.assertEqual(sleep.call_args_list, [mock.call(2), mock.call(4)])

    def test_inventory_retry_limit_and_timeout(self):
        for failure in (subprocess.TimeoutExpired("ssh", 45),
                        remote.TransientSSHError("SSH connection/channel unavailable")):
            with mock.patch.object(remote.subprocess, "run", side_effect=failure) as probe, mock.patch.object(
                    remote.time, "sleep") as sleep:
                with self.assertRaisesRegex(config.SessionError, "after 4 attempts"):
                    remote.inventory(host())
                self.assertEqual(probe.call_count, 4)
                self.assertEqual(sleep.call_args_list, [mock.call(2), mock.call(4), mock.call(8)])

    def test_inventory_permanent_errors_are_not_retried_or_disclosed(self):
        for rc, message, expected in (
                (255, "private-host: Permission denied (publickey).", "authentication failed"),
                (255, "private-host: Too many authentication failures", "rejected too many identities"),
                (255, "private-host: Host key verification failed.", "host key verification failed"),
                (71, "private-host diagnostic", "tmux inventory command failed")):
            with mock.patch.object(remote.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], rc, "", message)) as probe, mock.patch.object(remote.time, "sleep") as sleep:
                with self.assertRaisesRegex(config.SessionError, expected) as error:
                    remote.inventory(host())
                self.assertNotIn("private-host", str(error.exception))
                self.assertEqual(probe.call_count, 1)
                sleep.assert_not_called()

    def test_transient_creation_failure_does_not_retry_mutation(self):
        with mock.patch.object(remote, "inventory", return_value=([], set())), mock.patch.object(
                remote.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 255, "", "Connection reset by peer")) as probe, mock.patch.object(remote.time, "sleep") as sleep:
            with self.assertRaisesRegex(config.SessionError, "uncertain for oc-001"):
                remote.create(host())
            self.assertEqual(probe.call_count, 1)
            sleep.assert_not_called()

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
        self.assertEqual(launch.observe(self.state_path, state.state_key("endpoint", session()), set(), "$1"), "pending")

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

    def test_restore_requests_all_twenty_sessions_without_duplicates_on_repeat(self):
        sessions = [session("oc-{:03d}".format(i), "${}".format(i)) for i in range(1, 21)]
        result, output, errors = self.run_main(["restore", "alpha"], [(sessions, set())])
        self.assertEqual(result, 0)
        self.assertEqual(errors, "")
        self.assertIn("requested=20 skipped=0 failed=0", output)
        result, output, errors = self.run_main(["restore", "alpha"], [(sessions, set())])
        self.assertEqual(result, 0)
        self.assertEqual(errors, "")
        self.assertIn("requested=0 skipped=20 failed=0 pending=20", output)

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


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.output = io.TextIOWrapper(io.BytesIO())
        self.addCleanup(self.output.close)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(contextlib.redirect_stdout(self.output))
        for name, value in (("endpoint", "endpoint"), ("equivalent_aliases", {"dev-alpha"})):
            self.stack.enter_context(mock.patch.object(transport, name, return_value=value))
        self.legacy = self.stack.enter_context(mock.patch.object(transport, "local_legacy", return_value=set()))
        self.inventory = self.stack.enter_context(mock.patch.object(transport, "inventory", return_value=([session()], set())))
        self.launch = self.stack.enter_context(mock.patch.object(transport.subprocess, "Popen"))
        self.launch.return_value.__enter__.return_value.wait.return_value = 0
        self.relay = self.stack.enter_context(mock.patch.object(transport, "relay_output"))
        self.args = argparse.Namespace(token="a" * 48)
        self.handle = mock.Mock()
        self.identity = {key: session()[key] for key in ("sid", "created", "server")}

    def test_twenty_managed_tabs_connect_directly_without_inventory_probes(self):
        self.inventory.side_effect = config.SessionError("BatchMode probe must not gate managed tabs")
        for number in range(1, 21):
            identity = dict(self.identity, sid="${}".format(number))
            self.assertEqual(transport.attach_held(self.args, host(), [host()], identity, self.handle), 0)
            argv = self.launch.call_args.args[0]
            self.assertIn("-tt", argv)
            self.assertNotIn("BatchMode=yes", argv)
            self.assertIn("if-shell", argv[-1])
            self.assertIn(identity["sid"], argv[-1])
        self.assertEqual(self.launch.call_count, 20)
        self.inventory.assert_not_called()
        self.relay.call_args.args[2]("42")
        self.handle.write.assert_called_once_with(dict(phase="attaching", token=self.args.token, remote_pid="42"))

    def test_legacy_exact_and_ambiguous_attachments_still_block_duplicates(self):
        for target in ("oc-001", "$1", "oc-old-name"):
            self.legacy.return_value = {target}
            self.assertEqual(transport.attach_held(self.args, host(), [host()], self.identity, self.handle), 0)
        self.assertEqual(self.inventory.call_count, 3)
        self.launch.assert_not_called()

    def test_legacy_check_rejects_reused_identity_and_inspection_failure(self):
        self.legacy.return_value = {"oc-001"}
        self.inventory.return_value = ([dict(session(), created="999")], set())
        with self.assertRaisesRegex(config.SessionError, "no replacement attached"):
            transport.attach_held(self.args, host(), [host()], self.identity, self.handle)
        self.legacy.side_effect = config.SessionError("Cannot inspect current-account SSH attachments")
        with self.assertRaisesRegex(config.SessionError, "Cannot inspect"):
            transport.attach_held(self.args, host(), [host()], self.identity, self.handle)
        self.launch.assert_not_called()


class HostManagementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.inventory = self.root / "config/hosts.json"
        self.ssh = self.root / ".ssh/config"
        self.managed = self.root / ".ssh/aidevops.conf"
        self.home = mock.patch("pathlib.Path.home", return_value=self.root)
        self.home.start()
        self.addCleanup(self.home.stop)
        self.system_ssh = self.root / "etc/ssh/ssh_config"
        system = mock.patch.object(host_app, "SYSTEM_SSH_CONFIG", self.system_ssh)
        system.start()
        self.addCleanup(system.stop)

    def run_host(self, *args, allow_temp=True):
        arguments = ["host", *args, "--config", str(self.inventory)]
        if allow_temp:
            arguments.append("--allow-temporary-config")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(app.main(arguments), 0)
        return output.getvalue()

    def add(self, name="alpha", *args):
        return self.run_host("add", name, "--hostname", "server.invalid", *args)

    def test_cli_crud_and_effective_ssh(self):
        self.add("alpha", "--user", "generic", "--port", "2222")
        self.assertIn("alpha\talpha\toc-\tenabled", self.run_host("list"))
        self.assertIn('"titlePrefix": "alpha"', self.run_host("show", "alpha"))
        self.run_host("update", "alpha", "--hostname", "updated.invalid", "--title-prefix", "A", "--disabled")
        result = subprocess.run(  # nosec B603 - resolved executable; isolated config and fixed read-only probe
            [config.required_executable("ssh"), "-G", "-F", str(self.ssh), "alpha"], capture_output=True, text=True, check=True)
        self.assertIn("hostname updated.invalid\n", result.stdout)
        self.assertIn("user generic\n", result.stdout)
        self.assertIn("port 2222\n", result.stdout)
        self.assertIn("disabled", self.run_host("list"))
        self.run_host("remove", "alpha")
        self.assertIn(b"Host alpha", self.managed.read_bytes())
        self.assertEqual(json.loads(self.inventory.read_bytes())["hosts"], [])
        for path in (self.inventory, self.ssh, self.managed):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        backups = self.root / ".local/state/aidevops/tabby-host-config/backups"
        self.assertTrue(list(backups.glob("*.backup")))

    def test_dry_run_creates_nothing_and_temporary_target_is_explicit(self):
        with self.assertRaisesRegex(config.SessionError, "temporary inventory"):
            self.run_host("add", "alpha", "--hostname", "server.invalid", allow_temp=False)
        self.add("alpha", "--dry-run")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_identity_selection_defaults_and_inventory_only_updates(self):
        identity = self.root / "identity"
        identity.write_text("test identity placeholder\n")
        self.add("alpha", "--identity-file", str(identity))
        self.assertTrue(config.load_hosts(self.inventory, "alpha")[0]["identitiesOnly"])
        managed = self.managed.read_bytes()
        self.run_host("update", "alpha", "--no-identities-only")
        self.assertFalse(config.load_hosts(self.inventory, "alpha")[0]["identitiesOnly"])
        self.run_host("update", "alpha", "--identities-only")
        self.assertTrue(config.load_hosts(self.inventory, "alpha")[0]["identitiesOnly"])
        self.assertEqual(self.managed.read_bytes(), managed)
        self.add("beta", "--identity-file", str(identity), "--no-identities-only")
        self.assertFalse(config.load_hosts(self.inventory, "beta")[0]["identitiesOnly"])
        for name, expected in (("alpha", "yes"), ("beta", "no")):
            selected = config.load_hosts(self.inventory, name)[0]
            result = subprocess.run(  # nosec B603 - isolated config, local ssh -G only; no connection
                config.ssh_argv(selected) + ["-G", "-F", str(self.ssh), selected["sshHost"]],
                capture_output=True, text=True, check=True)
            self.assertIn("identitiesonly " + expected + "\n", result.stdout)
            self.assertIn("identityfile " + str(identity) + "\n", result.stdout)

    def test_existing_alias_registration_and_user_owned_protection(self):
        self.ssh.parent.mkdir()
        original = b"Host alpha\n  HostName existing.invalid\n"
        self.ssh.write_bytes(original)
        self.ssh.chmod(0o600)
        with mock.patch.object(host_app, "endpoint", return_value="resolved") as resolve:
            self.run_host("add", "alpha")
            resolve.assert_called_once()
        self.assertFalse(self.managed.exists())
        self.run_host("update", "alpha", "--session-prefix", "work-")
        for args in (("update", "alpha", "--hostname", "other.invalid"),
                     ("remove", "alpha", "--ssh")):
            with self.assertRaisesRegex(config.SessionError, "user-owned"):
                self.run_host(*args)
        self.assertEqual(self.ssh.read_bytes(), original)

    def test_conflicting_include_alias_and_managed_edit_are_refused(self):
        self.ssh.parent.mkdir()
        extra = self.ssh.parent / "custom.conf"
        extra.write_text("Host=alpha\n  HostName existing.invalid\n")
        self.ssh.write_text("Include custom.conf\n")
        extra.chmod(0o600)
        self.ssh.chmod(0o600)
        with self.assertRaisesRegex(config.SessionError, "user-owned"):
            self.add()
        self.assertFalse(self.inventory.exists())
        self.add("beta")
        self.managed.write_bytes(self.managed.read_bytes() + b"# manual change\n")
        with self.assertRaisesRegex(config.SessionError, "edited externally"):
            self.run_host("remove", "beta", "--ssh")

    def test_remove_ssh_and_shared_reference_guard(self):
        self.add()
        with mock.patch.object(host_app, "endpoint", return_value="resolved"):
            self.run_host("add", "other", "--ssh-host", "alpha")
        with self.assertRaisesRegex(config.SessionError, "referenced"):
            self.run_host("remove", "alpha", "--ssh")
        self.run_host("remove", "other")
        self.run_host("remove", "alpha", "--ssh")
        self.assertNotIn(b"Host alpha", self.managed.read_bytes())

    def test_root_owned_include_is_scanned_but_not_a_write_target(self):
        self.ssh.parent.mkdir()
        included = self.ssh.parent / "root.conf"
        self.ssh.write_text("Include root.conf\n")
        self.ssh.chmod(0o600)
        included.write_text("Host unrelated\n  HostName existing.invalid\n")
        included.chmod(0o644)
        original_stat = Path.stat

        def root_owned(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            if path == included:
                fields = list(info)
                fields[4] = 0
                return os.stat_result(fields)
            return info

        with mock.patch.object(Path, "stat", root_owned), mock.patch.object(os, "getuid", return_value=12345):
            self.assertFalse(ssh_scan.conflicts(included, "alpha", self.managed))
            with self.assertRaisesRegex(config.SessionError, "owned regular file"):
                host_files.snapshot(included)
        with mock.patch.object(Path, "stat", root_owned):
            self.add()
            included.write_text("Host beta\n  HostName existing.invalid\n")
            with self.assertRaisesRegex(config.SessionError, "user-owned"):
                self.add("beta")

    def test_system_alias_and_nested_relative_includes_prevent_mutation(self):
        self.system_ssh.parent.mkdir(parents=True)
        included = self.system_ssh.parent / "conf.d"
        included.mkdir()
        nested = included / "alias.conf"
        for content in ("Host alpha\n  HostName existing.invalid\n",
                        "Include conf.d/*.conf\n"):
            with self.subTest(content=content):
                self.system_ssh.write_text(content)
                self.system_ssh.chmod(0o644)
                nested.write_text("Include nested.conf\n")
                nested.chmod(0o644)
                target = self.system_ssh.parent / "nested.conf"
                target.write_text("Host alpha\n  HostName existing.invalid\n")
                target.chmod(0o644)
                with self.assertRaisesRegex(config.SessionError, "system SSH configuration"):
                    self.add()
                self.assertFalse(self.inventory.exists())
                self.assertFalse(self.ssh.exists())
                self.assertFalse(self.managed.exists())
                self.assertEqual(self.system_ssh.read_text(), content)

    def test_system_global_defaults_and_unrelated_alias_are_allowed(self):
        self.system_ssh.parent.mkdir(parents=True)
        original = "Host *\n  User baseline\nHost unrelated\n  HostName existing.invalid\n"
        self.system_ssh.write_text(original)
        self.system_ssh.chmod(0o644)
        self.add()
        self.assertEqual(self.system_ssh.read_text(), original)

    def test_scan_reader_retains_file_safety_checks(self):
        path = self.root / "scan.conf"
        path.write_text("Host alpha\n")
        path.chmod(0o666)
        with self.assertRaisesRegex(config.SessionError, "writable by other accounts"):
            ssh_scan.scan_snapshot(path)
        path.chmod(0o600)
        link = self.root / "link.conf"
        link.symlink_to(path)
        with self.assertRaisesRegex(config.SessionError, "symlinks"):
            ssh_scan.scan_snapshot(link)
        link.unlink()
        os.link(path, link)
        with self.assertRaisesRegex(config.SessionError, "without hard links"):
            ssh_scan.scan_snapshot(path)
        with self.assertRaisesRegex(config.SessionError, "regular file"):
            ssh_scan.scan_snapshot(self.root)
        link.unlink()
        with mock.patch.object(os, "getuid", return_value=12345):
            if path.stat().st_uid != 0:
                with self.assertRaisesRegex(config.SessionError, "user- or root-owned"):
                    ssh_scan.scan_snapshot(path)

    def test_validation_symlinks_and_injection(self):
        for args in (("--title-prefix", ""), ("--hostname", "x\nProxyCommand evil"), ("--port", "0")):
            with self.assertRaises(config.SessionError):
                self.add("alpha", *args)
        self.assertFalse(self.inventory.exists())
        other = self.root / "other"
        other.mkdir()
        self.inventory.parent.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(config.SessionError, "symlinks"):
            self.add()

    def test_partial_failure_restores_prior_file_contents(self):
        self.add()
        old_inventory = self.inventory.read_bytes()
        old_managed = self.managed.read_bytes()
        original_replace = host_files.replace

        def fail_inventory_once(path, content):
            if path == self.inventory:
                raise OSError("synthetic failure")
            original_replace(path, content)

        with mock.patch.object(host_files, "replace", side_effect=fail_inventory_once):
            with self.assertRaisesRegex(config.SessionError, "contents restored"):
                self.run_host("update", "alpha", "--hostname", "other.invalid", "--title-prefix", "A")
        self.assertEqual(self.inventory.read_bytes(), old_inventory)
        self.assertEqual(self.managed.read_bytes(), old_managed)

    def test_add_never_changes_existing_managed_alias(self):
        self.add()
        old = self.managed.read_bytes()
        with self.assertRaisesRegex(config.SessionError, "already managed"):
            self.run_host("add", "other", "--ssh-host", "alpha", "--hostname", "other.invalid")
        with self.assertRaisesRegex(config.SessionError, "casing"):
            self.add("ALPHA")
        self.assertEqual(self.managed.read_bytes(), old)

    def test_identity_spaces_ipv6_and_missing_key_removal(self):
        key = self.root / "key with spaces"
        key.touch()
        self.run_host("add", "alpha", "--hostname", "::1", "--identity-file", str(key))
        result = subprocess.run(  # nosec B603 - resolved executable; isolated config and fixed read-only probe
            [config.required_executable("ssh"), "-G", "-F", str(self.ssh), "alpha"], capture_output=True, text=True, check=True)
        self.assertIn("hostname ::1\n", result.stdout)
        self.assertIn("identityfile " + str(key) + "\n", result.stdout)
        key.unlink()
        self.run_host("remove", "alpha", "--ssh")

    def test_shell_launcher_and_existing_global_scope(self):
        self.ssh.parent.mkdir()
        original = b"Match all\n  User baseline\nHost unrelated\n  HostName original.invalid\n"
        self.ssh.write_bytes(original)
        self.ssh.chmod(0o600)
        # Exercise writes with the isolated system fixture; the launcher process
        # cannot inherit mock patches and must not depend on host-wide SSH config.
        self.add("alpha", "--user", "generic")
        launcher = Path(__file__).resolve().parents[1] / "tabby-session-helper.sh"
        environment = dict(os.environ, HOME=str(self.root), AIDEVOPS_TABBY_HOSTS=str(self.inventory))
        result = subprocess.run(  # nosec B603 - resolved shell; repository launcher and isolated HOME
                                [config.required_executable("bash"), str(launcher), "host", "list"], env=environment,
                                 capture_output=True, text=True, check=True)
        self.assertIn("alpha\talpha\toc-\tenabled", result.stdout)
        self.assertTrue(self.ssh.read_bytes().endswith(original))
        result = subprocess.run(  # nosec B603 - resolved executable; isolated config and fixed read-only probe
                                [config.required_executable("ssh"), "-G", "-F", str(self.ssh), "unrelated"],
                                capture_output=True, text=True, check=True)
        self.assertIn("hostname original.invalid\n", result.stdout)
        self.assertIn("user baseline\n", result.stdout)

    def test_conditional_match_rules_are_refused_without_mutation(self):
        self.ssh.parent.mkdir()
        included = self.ssh.parent / "conditional.conf"
        for rule in ("originalhost alpha", "host alpha", 'exec "false"'):
            for via_include in (False, True):
                with self.subTest(rule=rule, via_include=via_include):
                    content = ("Match " + rule + "\n  HostName original.invalid\n").encode()
                    included.write_bytes(content)
                    included.chmod(0o600)
                    original = b"Include conditional.conf\n" if via_include else content
                    self.ssh.write_bytes(original)
                    self.ssh.chmod(0o600)
                    with self.assertRaisesRegex(config.SessionError, "Conditional SSH Match"):
                        self.add()
                    self.assertEqual(self.ssh.read_bytes(), original)
                    self.assertEqual(included.read_bytes(), content)
                    self.assertFalse(self.managed.exists())
                    self.assertFalse(self.inventory.exists())

    def test_busy_lock_fails_without_changing_configuration(self):
        self.add()
        original = self.inventory.read_bytes()
        lock = self.inventory.parent / ".aidevops-tabby-hosts.lock"
        with lock.open("rb") as held:
            host_files.fcntl.flock(held, host_files.fcntl.LOCK_EX | host_files.fcntl.LOCK_NB)
            with self.assertRaisesRegex(config.SessionError, "configuration is busy"):
                self.run_host("update", "alpha", "--title-prefix", "A")
        self.assertEqual(self.inventory.read_bytes(), original)
        self.run_host("update", "alpha", "--title-prefix", "A")

    def test_inventory_metadata_survives_host_edits(self):
        self.inventory.parent.mkdir()
        data = {"version": 1, "hosts": [], "$schema": "local-schema", "notes": {"owner": "operator"}}
        self.inventory.write_text(json.dumps(data))
        self.inventory.chmod(0o600)
        self.add()
        self.run_host("update", "alpha", "--title-prefix", "A")
        self.assertEqual([h["id"] for h in config.load_hosts(self.inventory)], ["alpha"])
        self.run_host("remove", "alpha", "--ssh")
        self.assertEqual(json.loads(self.inventory.read_bytes()), data)


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
