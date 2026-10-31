#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Advisory-only Docker ownership context for the Claude hook."""
import hashlib
import json
import re
import shlex
import sys
from pathlib import Path

GLOBAL_VALUES = {"--config", "--context", "-c", "--host", "-H", "--log-level", "-l",
                 "--tlscacert", "--tlscert", "--tlskey"}
BOOLEAN_OPTIONS = {"--detach", "--interactive", "--tty", "--init", "--privileged",
                   "--read-only", "--publish-all", "--oom-kill-disable", "--sig-proxy",
                   "--use-api-socket", "--help", "--internal", "--attachable",
                   "--ingress", "--ipv6", "--config-only", "-q", "--quiet",
                   "--no-healthcheck"}


def _creation_args(words):
    """Discard global options and normalize Docker resource subcommands."""
    index = 0
    while index < len(words) and words[index].startswith("-"):
        option = words[index].split("=", 1)[0]
        index += 2 if option in GLOBAL_VALUES and "=" not in words[index] else 1
    args = words[index:]
    if args[:1] == ["container"]:
        args = args[1:]
    if args[:2] in (["network", "create"], ["volume", "create"]):
        args = args[1:]
    return args


def _option_value(args, index):
    """Read an option without mistaking its value for another option."""
    option, equal, value = args[index].partition("=")
    if equal:
        return option, value, index
    if option in {"--label", "-l"}:
        index += 1
        return option, args[index] if index < len(args) else "", index
    takes_value = (option != "--rm" and option not in BOOLEAN_OPTIONS
                   and not re.fullmatch(r"-[ditP]+", option))
    return option, "true", index + int(bool(takes_value))


def _creation_has_owner(args):
    """Inspect literal Docker options, never image commands or option values."""
    owner = False
    remove = False
    index = 1
    while index < len(args):
        if not args[index].startswith("-") or args[index] == "--":
            break
        option, value, index = _option_value(args, index)
        if option == "--rm":
            remove = value == "true"
        if option in {"--label", "-l"} and value.startswith("sh.aidevops.owner="):
            owner = value == "sh.aidevops.owner=1"
        index += 1
    return owner or (args[0] == "run" and remove)


def _docker_creation_needs_owner(words):
    """Leave shell expansions and Compose's external labels indeterminate."""
    if any(re.search(r"[$`]", word) for word in words):
        return False
    args = _creation_args(words)
    return args[:1] in (["run"], ["create"]) and not _creation_has_owner(args)


def _docker_shell_parts(command):
    """Split literal shell segments without cutting quoted or escaped separators."""
    part = []
    quote = ""
    index = 0
    while index < len(command):
        char = command[index]
        if char == "\\" and quote != "'" and index + 1 < len(command):
            following = command[index + 1]
            if following != "\n":
                part.extend((char, following))
            index += 2
            continue
        if quote:
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char in ";&|\n":
            yield "".join(part)
            part = []
            index += 1
            continue
        part.append(char)
        index += 1
    yield "".join(part)


def docker_owner_advisory(command: str, session_id: str):
    """Return non-blocking context once per Claude session, never a decision."""
    needs_labels = False
    for part in _docker_shell_parts(command):
        match = re.search(r"(?:^|\s)docker\s+(.+)", part, re.DOTALL)
        if not match:
            continue
        try:
            needs_labels |= _docker_creation_needs_owner(shlex.split(match.group(1)))
        except ValueError:
            continue  # Incomplete shell input must never block a command.
    if not needs_labels or not session_id:
        return None
    marker_dir = Path.home() / ".aidevops" / ".agent-workspace" / "tmp" / "docker-advisory"
    marker = marker_dir / hashlib.sha256(session_id.encode()).hexdigest()
    try:
        marker_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with marker.open("x"):
            pass
    except OSError:
        # Existing marker or unwritable state must never block the command.
        return None
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": "Docker test resources need owner labels: use "
        "docker-resource-helper.sh labels / compose-labels; see "
        "tools/containers/disposable-resources.md. Advisory only; user-owned stacks are unchanged.",
    }}


if __name__ == "__main__":
    print(json.dumps(docker_owner_advisory(sys.argv[1], sys.argv[2]) or {}))
