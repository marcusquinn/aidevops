#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Native multi-host Tabby/tmux orchestration. No daemon or remote setup."""

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

if sys.version_info < (3, 9):
    sys.exit("Python 3.9+ is required; no packages will be installed")

from tabby_session_config import SessionError, check_tabby, endpoint, equivalent_aliases, load_hosts, tabby_executable
from tabby_session_legacy import legacy_state, local_legacy
from tabby_session_remote import attach_command, create, inventory
from tabby_session_state import lease, state_directory, state_key


def report(host, session, status, detail=""):
    print("{}\t{}\t{}{}".format(host["id"], session["name"], status, "\t" + detail if detail else ""), flush=True)


def paths():
    config = os.environ.get("AIDEVOPS_TABBY_HOSTS", str(Path.home() / ".config/aidevops/tabby-hosts.json"))
    state = os.environ.get("AIDEVOPS_TABBY_STATE_DIR", str(Path.home() / ".local/state/aidevops/tabby-sessions"))
    return str(Path(config).absolute()), str(Path(state).absolute())


def launch_argv(binary, config, state, key, token, host, session):
    # Tabby 1.0.236's array option; never join shell fragments or use eval.
    command = [sys.executable, str(Path(__file__).absolute()), "_attach", host["id"],
               "--config", config, "--state-dir", state, "--key", key, "--token", token,
               "--identity", ":".join(session[k] for k in ("sid", "created", "server"))]
    return [binary, "run"] + ["--command=" + arg for arg in command]


def request(binary, config, state, host, session, endpoint_id, clients, legacy, sessions):
    status = legacy_state(legacy, session, sessions)
    if status:
        report(host, session, "skipped", status)
        return "skipped"
    key = state_key(endpoint_id, session)
    directory = state_directory(state)
    try:
        with lease(directory, key) as handle:
            status = handle.observe(clients, session["sid"])
            if status != "missing":
                report(host, session, "skipped", status)
                return status
            token = handle.reserve()
    finally:
        os.close(directory)
    try:
        result = subprocess.run(launch_argv(binary, config, state, key, token, host, session),
                                capture_output=True, timeout=20, check=False)
        if result.returncode:
            raise SessionError("Tabby launch failed; remote session retained")
    except (OSError, subprocess.TimeoutExpired, SessionError):
        # Leave the bounded token in place: even a timeout/nonzero exit can have
        # delivered a delayed confirmation to Tabby. A later wrapper must still
        # arbitrate the lease. No second launch until expiry.
        report(host, session, "failed", "launch uncertain; remote work retained; retry restore after 120s")
        return "failed"
    report(host, session, "requested", "pending Run/authentication; not proof of attachment")
    return "requested"


def observe(state, key, clients, sid):
    try:
        directory = state_directory(state, create=False)
    except FileNotFoundError:
        return "missing"
    try:
        with lease(directory, key, create=False) as handle:
            return handle.observe(clients, sid)
    except FileNotFoundError:
        return "missing"
    finally:
        os.close(directory)


def host_action(args, host, hosts, binary):
    endpoint_id = endpoint(host)
    aliases = equivalent_aliases(hosts, host, endpoint_id)
    legacy = local_legacy(aliases)
    sessions, clients = inventory(host)
    if args.action == "new" and not args.dry_run:
        session, clients = create(host)
        sessions = [session]
        report(host, session, "created", "detached; recover with aidevops tabby sessions restore " + host["id"])
        yield "created"
    for session in sessions:
        if args.action == "list" or args.dry_run:
            status = legacy_state(legacy, session, sessions) or observe(
                args.state_dir, state_key(endpoint_id, session), clients, session["sid"])
            report(host, session, status, "dry-run" if args.dry_run else "")
            yield "skipped" if status.startswith("legacy") else status
            continue
        # Re-inspect legacy SSH before each request (including another restore).
        outcome = request(binary, args.config, args.state_dir, host, session, endpoint_id,
                          clients, local_legacy(aliases), sessions)
        yield outcome
        if outcome == "requested":
            time.sleep(host["connectIntervalSeconds"])
    if not sessions:
        print(host["id"] + "\tempty", flush=True)
    if args.action == "new" and args.dry_run:
        print(host["id"] + "\twould-create-next-numbered-session (no mutation)")


def doctor(args, hosts):
    failures = 0
    try:
        binary = tabby_executable()
        print("Tabby CLI: " + check_tabby(binary) + " (array transport probe only)")
    except (SessionError, OSError) as exc:
        print("Tabby CLI: " + safe_error(exc))
        failures += 1
    print("Python: {}.{}; no package installation".format(*sys.version_info[:2]))
    # Check existing state only; doctor never creates locks/directories.
    try:
        fd = state_directory(args.state_dir, create=False)
        os.close(fd)
        print("State: private directory verified")
    except FileNotFoundError:
        print("State: not initialized (created on first launch)")
    except (SessionError, OSError) as exc:
        print("State: " + safe_error(exc))
        failures += 1
    for host in hosts:
        try:
            endpoint(host)  # ssh -G only: no network connection.
            print(host["id"] + ": config valid; OpenSSH resolved privately")
            if args.remote:
                sessions, _clients = inventory(host)
                print(host["id"] + ": remote tmux probe passed; {} matching sessions".format(len(sessions)))
        except (SessionError, OSError) as exc:
            print(host["id"] + ": " + safe_error(exc))
            failures += 1
    print("Remote probes: " + ("explicit, read-only" if args.remote else "not requested"))
    print("Live attachment, dynamic titles and clipboard permissions: not verified by doctor")
    return int(failures > 0)


def relay_output(stream, marker, connected, output):
    """Strip one PID protocol marker without buffering terminal prompts/logging."""
    prefix, pending, found = marker.encode(), b"", False
    while True:
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            break
        if found:
            output.write(chunk)
            output.flush()
            continue
        for byte in chunk:
            if found:
                output.write(bytes([byte]))
                continue
            pending += bytes([byte])
            if pending.startswith(prefix):
                suffix = pending[len(prefix):]
                if re.fullmatch(rb"[0-9]+\r?\n", suffix):
                    connected(suffix.strip().decode())
                    pending, found = b"", True
                elif len(suffix) > 32:
                    output.write(pending)
                    pending = b""
            elif not prefix.startswith(pending):
                output.write(pending)
                pending = b""
        output.flush()
    if pending:
        output.write(pending)
        output.flush()


def attach(args, host, hosts):
    if not re.fullmatch(r"\$[0-9]+:[0-9]+:[0-9]+", args.identity or ""):
        raise SessionError("Invalid attachment identity")
    sid, created, server = args.identity.split(":")
    session = {"sid": sid, "created": created, "server": server}
    endpoint_id = endpoint(host)
    if args.key != state_key(endpoint_id, session):
        raise SessionError("Host configuration changed; run restore again")
    directory = state_directory(args.state_dir, create=False)
    try:
        with lease(directory, args.key, create=False) as handle:
            if not handle.claim(args.token):
                raise SessionError("Expired, replaced or already claimed launch; run restore")
            try:
                return attach_held(args, host, hosts, session, endpoint_id, handle)
            finally:
                handle.write({"phase": "idle"})
    finally:
        os.close(directory)


def attach_held(args, host, hosts, session, endpoint_id, handle):
    sessions, _clients = inventory(host)
    current = next((s for s in sessions if all(s[k] == session[k] for k in session)), None)
    if current is None:
        raise SessionError("Session disappeared/renamed outside prefix; no replacement attached")
    aliases = equivalent_aliases(hosts, host, endpoint_id)
    if legacy_state(local_legacy(aliases), current, sessions):
        report(host, current, "skipped", "legacy SSH attachment")
        return 0
    marker = "AIDEVOPS_TABBY_" + args.token + ":"
    command = attach_command(host, session, marker)
    # OpenSSH closes inherited extra FDs. Orphan recovery instead recognizes the
    # exact launch nonce in current-account SSH argv, never a numeric PID alone.
    with subprocess.Popen(command, stdout=subprocess.PIPE) as child:
        try:
            relay_output(child.stdout, marker, lambda pid: handle.write(
                {"phase": "attaching", "token": args.token, "remote_pid": pid}), sys.stdout.buffer)
            return child.wait()
        except BaseException:
            # Only the owned local SSH transport is stopped, never remote tmux.
            child.terminate()
            child.wait()
            raise


def parser():
    config, state = paths()
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("action", choices=("new", "restore", "list", "doctor", "_attach"))
    result.add_argument("host", nargs="?")
    result.add_argument("--dry-run", action="store_true", help="read remote inventory; create no sessions/reservations/tabs")
    result.add_argument("--remote", action="store_true", help="doctor: explicitly probe remote tmux (read-only)")
    result.add_argument("--config", default=config)
    result.add_argument("--state-dir", default=state)
    for option in ("key", "token", "identity"):
        result.add_argument("--" + option, help=argparse.SUPPRESS)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    args.config = str(Path(args.config).absolute())
    args.state_dir = str(Path(args.state_dir).absolute())
    if args.action in ("new", "_attach") and not args.host:
        raise SessionError("This command requires a host ID")
    hosts = load_hosts(args.config)
    selected = load_hosts(args.config, args.host)
    if args.action == "doctor":
        return doctor(args, selected)
    if args.remote:
        raise SessionError("--remote is only valid with doctor")
    if args.action == "_attach":
        if args.dry_run:
            raise SessionError("Internal attachment cannot be combined with --dry-run")
        return attach(args, selected[0], hosts)
    binary = None
    if args.action in ("new", "restore") and not args.dry_run:
        binary = tabby_executable()
        check_tabby(binary)
    totals = dict.fromkeys(("requested", "skipped", "failed", "pending", "connected", "missing", "created"), 0)
    for host in selected:
        try:
            for outcome in host_action(args, host, hosts, binary):
                totals[outcome] += 1
                if outcome in ("pending", "connected") and args.action != "list" and not args.dry_run:
                    totals["skipped"] += 1
        except (SessionError, OSError) as exc:
            print(host["id"] + "\tfailed\t" + safe_error(exc), file=sys.stderr)
            totals["failed"] += 1
    print("Summary: " + " ".join("{}={}".format(k, v) for k, v in totals.items()))
    print("Use list for pending/connected observations; requested does not mean authenticated")
    return int(totals["failed"] > 0)


def safe_error(exc):
    return str(exc) if isinstance(exc, SessionError) else "Local operation failed (private details withheld)"


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SessionError, OSError) as error:
        print(safe_error(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Cancelled; remote work preserved", file=sys.stderr)
        sys.exit(130)
