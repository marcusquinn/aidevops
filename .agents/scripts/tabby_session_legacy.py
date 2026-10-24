# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conservative current-account direct-SSH detection; never print process argv."""

import os
import re
import shlex
import subprocess
from pathlib import Path

from tabby_session_config import SessionError, required_executable


def legacy_targets(text, aliases):
    targets = set()
    for line in text.splitlines():
        try:
            args = shlex.split(line)
        except ValueError:
            continue
        target = legacy_target(args, aliases)
        if target:
            targets.add(target)
    return targets


def legacy_target(args, aliases):
    if not args or Path(args[0]).name != "ssh":
        return None
    index = legacy_destination(args)
    if index >= len(args) or args[index] not in aliases:
        return None
    command = args[index + 1:]
    if len(command) == 1:
        try:
            command = shlex.split(command[0])
        except ValueError:
            return None
    return legacy_command_target(command)


def legacy_command_target(command):
    if len(command) != 4:
        return None
    if command[0] != "tmux" or command[2] != "-t":
        return None
    if command[1] in ("attach", "attach-session"):
        return command[3].removeprefix("=")
    return None


def legacy_destination(args):
    index = 1
    while index < len(args):
        if args[index] in ("-t", "-tt", "-T"):
            index += 1
        elif args[index] == "-i" and index + 1 < len(args):
            index += 2
        elif args[index] == "-o" and index + 1 < len(args) and (
                args[index + 1].startswith("ConnectTimeout=") or args[index + 1] == "IdentitiesOnly=yes"):
            index += 2
        else:
            break
    return index


def local_processes():
    try:
        result = subprocess.run(  # nosec B603 - resolved ps path, fixed current-account-only argv
                                [required_executable("ps"), "-ww", "-U", str(os.getuid()), "-o", "args="],
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("Cannot inspect current-account SSH attachments; refusing duplicate-risk launch") from None
    if result.returncode:
        raise SessionError("Cannot inspect current-account SSH attachments")
    return result.stdout


def local_legacy(aliases):
    return legacy_targets(local_processes(), aliases)


def local_managed(nonce):
    """Recover orphaned SSH without trusting a reusable numeric local PID."""
    if not isinstance(nonce, str) or not re.fullmatch(r"[a-f0-9]{48}", nonce):
        return False
    marker = "AIDEVOPS_TABBY_" + nonce + ":"
    for line in local_processes().splitlines():
        # ps does not retain argv quoting; a nonce is restricted ASCII and its
        # full protocol marker can be recognized without reconstructing a shell.
        words = line.split()
        if words and Path(words[0]).name == "ssh" and marker in line:
            return True
        if managed_wrapper(words, nonce, line):
            return True
    return False


def managed_wrapper(words, nonce, line):
    if not words or not Path(words[0]).name.startswith("python"):
        return False
    if not any(Path(word).name == "tabby_sessions.py" for word in words):
        return False
    return "_attach" in words and "--token " + nonce in line


def legacy_state(targets, session, sessions):
    if session["name"] in targets or session["sid"] in targets:
        return "legacy"
    known = {s["name"] for s in sessions} | {s["sid"] for s in sessions}
    # A name in an existing SSH command may have been renamed remotely. Without
    # a stable-ID lease its exact identity cannot be proven: fail closed per host.
    if targets - known:
        return "legacy-ambiguous"
    return None
