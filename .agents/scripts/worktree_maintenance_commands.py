#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only Git/GitHub commands and retention checks for maintenance plans."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from worktree_maintenance_boundary import require

SCRIPTS = Path(__file__).resolve().parent


def executable(name):
    require(name in {"git", "gh", "bash"}, "maintenance:unsupported-command")
    path = shutil.which(name)
    require(path is not None, "maintenance:command-unavailable:" + name)
    return os.path.abspath(path)


def command(arguments):
    argv = [executable(arguments[0]), *arguments[1:]]
    # Internal argv builders only; data stays in separate arguments, never shell text.
    result = subprocess.run(argv, capture_output=True, text=True, timeout=30,  # nosec B603
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    if result.returncode and arguments[:2] == ["bash", str(SCRIPTS / "worktree-maintenance-policy.sh")]:
        reason = result.stdout.strip()
        if re.fullmatch(r"(?:protected-[a-z-]+|preserve-forensics|archive-policy-unverified|open-pr)", reason):
            raise ValueError("maintenance:retention-policy:" + reason)
    require(result.returncode == 0, "maintenance:command-failed:" + arguments[0])
    return result.stdout.strip()


def git(path, *arguments):
    return command(["git", "-C", str(path), *arguments])


def repository(path):
    remote = git(path, "remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github[.]com/|git@github[.]com:)([\w.-]+/[\w.-]+?)(?:[.]git)?", remote)
    require(match is not None, "maintenance:unsupported-remote")
    slug = match[1]
    metadata = json.loads(command(["gh", "api", "repos/" + slug]))
    default = metadata["default_branch"]
    tip = json.loads(command(["gh", "api", f"repos/{slug}/git/ref/heads/{default}"]))["object"]["sha"]
    require(git(path, "rev-parse", "refs/remotes/origin/" + default) == tip,
            "maintenance:refresh-default-ref-before-planning")
    return {"path": str(path), "slug": slug, "default": default, "tip": tip}
