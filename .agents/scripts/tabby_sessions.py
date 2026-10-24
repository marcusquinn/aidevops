#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Native multi-host Tabby/tmux orchestration. No daemon or remote setup."""

import argparse
import os
import sys
import time
from pathlib import Path

if sys.version_info < (3, 9):
    sys.exit("Python 3.9+ is required; no packages will be installed")

from tabby_session_config import SessionError, endpoint, equivalent_aliases, load_hosts
from tabby_session_launch import LaunchContext, check_tabby, observe, report, request, tabby_executable
from tabby_session_legacy import legacy_state, local_legacy
from tabby_session_remote import create, inventory
from tabby_session_state import state_directory, state_key
from tabby_session_transport import attach


def paths():
    config = os.environ.get("AIDEVOPS_TABBY_HOSTS", str(Path.home() / ".config/aidevops/tabby-hosts.json"))
    state = os.environ.get("AIDEVOPS_TABBY_STATE_DIR", str(Path.home() / ".local/state/aidevops/tabby-sessions"))
    return str(Path(config).absolute()), str(Path(state).absolute())


def describe_session(context, session, legacy):
    status = legacy_state(legacy, session, context.sessions) or observe(
        context.args.state_dir, state_key(context.endpoint_id, session), context.clients, session["sid"])
    report(context.host, session, status, "dry-run" if context.args.dry_run else "")
    return "skipped" if status.startswith("legacy") else status


def host_action(args, host, hosts, binary):
    endpoint_id = endpoint(host)
    aliases = equivalent_aliases(hosts, host, endpoint_id)
    sessions, clients = inventory(host)
    if args.action == "new" and not args.dry_run:
        session, clients = create(host)
        sessions = [session]
        report(host, session, "created", "detached; recover with aidevops tabby sessions restore " + host["id"])
        yield "created"
    context = LaunchContext(args, binary, host, endpoint_id, clients, sessions)
    for session in sessions:
        # Refresh legacy evidence before each request, including wrapper start.
        legacy = local_legacy(aliases)
        if args.action == "list" or args.dry_run:
            yield describe_session(context, session, legacy)
        else:
            outcome = request(context, session, legacy)
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
    return run_hosts(args, selected, hosts, binary)


def run_hosts(args, selected, hosts, binary):
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
