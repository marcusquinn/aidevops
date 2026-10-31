# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Claim a pending local lease and supervise its owned interactive SSH."""

import os
import re
import subprocess
import sys

from tabby_session_config import SessionError, endpoint, equivalent_aliases
from tabby_session_launch import report
from tabby_session_legacy import legacy_state, local_legacy
from tabby_session_remote import attach_command, inventory
from tabby_session_state import lease, state_directory, state_key
from tabby_session_terminal import relay_output


def attach(args, host, hosts):
    if not re.fullmatch(r"\$[0-9]+:[0-9]+:[0-9]+", args.identity or ""):
        raise SessionError("Invalid attachment identity")
    sid, created, server = args.identity.split(":")
    session = {"sid": sid, "created": created, "server": server}
    if args.key != state_key(endpoint(host), session):
        raise SessionError("Host configuration changed; run restore again")
    directory = state_directory(args.state_dir, create=False)
    try:
        with lease(directory, args.key, create=False) as handle:
            if not handle.claim(args.token):
                raise SessionError("Expired, replaced or already claimed launch; run restore")
            try:
                return attach_held(args, host, hosts, session, handle)
            finally:
                handle.write({"phase": "idle"})
    finally:
        os.close(directory)


def attach_held(args, host, hosts, session, handle):
    sessions, _clients = inventory(host)
    current = next((s for s in sessions if all(s[k] == session[k] for k in session)), None)
    if current is None:
        raise SessionError("Session disappeared/renamed outside prefix; no replacement attached")
    aliases = equivalent_aliases(hosts, host, endpoint(host))
    if legacy_state(local_legacy(aliases), current, sessions):
        report(host, current, "skipped", "legacy SSH attachment")
        return 0
    marker = "AIDEVOPS_TABBY_" + args.token + ":"
    command = attach_command(host, session, marker)
    # OpenSSH closes extra FDs. Orphan recovery uses the exact nonce, not PIDs.
    with subprocess.Popen(command, stdout=subprocess.PIPE) as child:  # nosec B603 - validated SSH argv, quoted remote script
        try:
            relay_output(child.stdout, marker, lambda pid: handle.write(
                {"phase": "attaching", "token": args.token, "remote_pid": pid}), sys.stdout.buffer)
            return child.wait()
        except BaseException:
            # Only this owned local SSH transport, never the remote tmux process.
            child.terminate()
            child.wait()
            raise
