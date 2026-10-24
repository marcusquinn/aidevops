# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Small POSIX remote protocol: never change remote configuration or kill work."""

import re
import shlex
import subprocess

from tabby_session_config import SessionError, ssh_argv


class CreationCollision(SessionError):
    """Only a verified tmux duplicate-name response authorizes a new attempt."""


INVENTORY = r"""
command -v tmux >/dev/null 2>&1 || exit 127
export LC_ALL=C
out=$(tmux list-sessions -F 'S\t#{session_id}\t#{session_created}\t#{pid}\t#{session_name}' 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    case "$out" in
        *'no server running'*|*'no sessions'*|*'No such file or directory'*) exit 0 ;;
        *) exit 71 ;;
    esac
fi
printf '%s\n' "$out"
tmux list-clients -F 'C\t#{client_pid}\t#{session_id}' || exit 71
""".replace(r"\t", "\t")


def remote(host, script):
    try:
        result = subprocess.run(ssh_argv(host) + [host["sshHost"], "sh -c " + shlex.quote(script)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("SSH probe failed or timed out (no authentication logs retained)") from None
    if result.returncode == 127:
        raise SessionError("Remote tmux is unavailable")
    if result.returncode == 75:
        raise CreationCollision("Concurrent tmux creation collision")
    if result.returncode:
        raise SessionError("SSH/tmux probe failed; prepare agent/MFA or SSH multiplexing privately")
    return result.stdout


def natural_key(name, prefix):
    suffix = name[len(prefix):]
    return (0, int(suffix), name) if suffix.isascii() and suffix.isdigit() else (1, 0, name)


def inventory(host):
    sessions, clients = [], set()
    for line in remote(host, INVENTORY).splitlines():
        fields = line.split("\t")
        if len(fields) == 5 and fields[0] == "S":
            _, sid, created, server, name = fields
            if not re.fullmatch(r"\$[0-9]+", sid) or not created.isdigit() or not server.isdigit():
                raise SessionError("Invalid tmux session identity")
            # Reject rather than interpolate names containing shell/format metacharacters.
            if name.startswith(host["sessionPrefix"]):
                if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name):
                    raise SessionError("Unsupported tmux session name; use letters, digits, dot, dash, underscore")
                sessions.append({"sid": sid, "created": created, "server": server, "name": name})
        elif len(fields) == 3 and fields[0] == "C" and fields[1].isdigit():
            clients.add((fields[1], fields[2]))
        elif line:
            raise SessionError("Unexpected tmux inventory response")
    return sorted(sessions, key=lambda s: natural_key(s["name"], host["sessionPrefix"])), clients


def create(host):
    for _ in range(5):
        sessions, _clients = inventory(host)
        suffixes = [int(s["name"][len(host["sessionPrefix"]):]) for s in sessions
                    if s["name"][len(host["sessionPrefix"]):].isascii()
                    and s["name"][len(host["sessionPrefix"]):].isdigit()]
        number = max(suffixes, default=0) + 1
        if number > 999999999:
            raise SessionError("Numbered session range exhausted")
        name = host["sessionPrefix"] + format(number, "03d")
        script = "command -v tmux >/dev/null 2>&1 || exit 127\nexport LC_ALL=C\n" + (
            "out=$(tmux new-session -d -s " + shlex.quote(name) + " -P -F '#{session_id}' 2>&1)\n"
            "rc=$?\n"
            "if [ \"$rc\" -eq 0 ]; then printf '%s\\n' \"$out\"; else\n"
            "case \"$out\" in 'duplicate session:'*) exit 75 ;; *) exit 71 ;; esac\nfi")
        # tmux itself arbitrates creation: never attach to a colliding name.
        try:
            sid = remote(host, script).strip()
        except CreationCollision:
            continue
        except SessionError as exc:
            # A lost reply may hide successful creation. Never allocate another
            # session merely because a subsequent inventory contains that name.
            raise SessionError("Creation failed/uncertain for " + name + ": " + str(exc)
                               + "; use list/restore before retrying new") from None
        try:
            current, clients = inventory(host)
        except SessionError:
            raise SessionError("Created " + name + "; refresh failed; use list/restore to recover") from None
        for session in current:
            if session["sid"] == sid:
                return session, clients
        raise SessionError("Session created but refresh failed; list/restore to recover remote work")
    raise SessionError("Concurrent creation collisions; retry new (existing work preserved)")


def attach_command(host, session, marker):
    # Explicit POSIX shell even when the account's login shell is fish/csh.
    script = "printf '%s%s\\n' " + shlex.quote(marker) + ' "$$" >&2\n'
    script += "exec tmux attach-session -t " + shlex.quote(session["sid"])
    return ssh_argv(host, probe=False) + [host["sshHost"], "sh -c " + shlex.quote(script)]
