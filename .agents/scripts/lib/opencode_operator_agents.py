"""Explicit, local OpenCode operator workers under Build+ default-deny Task rules."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import os
import re
import sys

from discovery_utils import parse_frontmatter

OPERATOR_NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]*\Z")
GENERATED_MARKER = "<!-- aidevops:generated-subagent -->"
LEGACY_STUB = "**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/"


def _owner_controlled_file(path):
    """Reject symlinks, missing files, and group/other-writable inputs."""
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    info = os.stat(path)
    return info.st_uid == os.getuid() and not info.st_mode & 0o022


def _operator_agent_exists(agent_dir, name):
    path = os.path.join(agent_dir, f"{name}.md")
    if not _owner_controlled_file(path):
        return False
    try:
        with open(path, encoding="utf-8") as handle:
            content = handle.read()
    except OSError:
        return False
    return (parse_frontmatter(path).get("mode") == "subagent" and
            GENERATED_MARKER not in content and LEGACY_STUB not in content)


def _read_operator_allowlist(config_dir):
    allowlist = os.path.join(config_dir, "aidevops", "opencode-operator-subagents.txt")
    if not os.path.exists(allowlist):
        return []
    if not _owner_controlled_file(allowlist):
        print("  Warning: operator subagent allowlist is not owner-controlled", file=sys.stderr)
        return []
    try:
        with open(allowlist, encoding="utf-8") as handle:
            return handle.readlines()
    except OSError as error:
        print(f"  Warning: cannot read operator subagent allowlist: {error}", file=sys.stderr)
        return []


def extend_opencode_operator_subagents(primary_agents, config_dir=None):
    """Allow exact opted-in, existing operator files; return validated names."""
    config_dir = config_dir or os.path.expanduser("~/.config")
    agent_dir = os.path.join(config_dir, "opencode", "agent")
    accepted = set()
    for raw in _read_operator_allowlist(config_dir):
        name = raw.strip()
        if not name or name.startswith("#"):
            continue
        if not OPERATOR_NAME.fullmatch(name):
            print(f"  Warning: invalid operator subagent name: {name!r}", file=sys.stderr)
        elif not _operator_agent_exists(agent_dir, name):
            print(f"  Warning: not an operator-owned subagent: {name}", file=sys.stderr)
        else:
            accepted.add(name)
    task = primary_agents.get("Build+", {}).get("permission", {}).get("task")
    if isinstance(task, dict) and task.get("*") == "deny":
        for name in sorted(accepted):
            task[name] = "allow"
    return accepted
