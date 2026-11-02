#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Resolve the Git resources a declared tool command targets (GH#36430)."""

import json
import os
from pathlib import Path

from canonical_git_invocation import split_invocation
from canonical_git_policy import _git_repo_identity
from command_policy_parser import _shell_invocations
from native_git import real_git

REPOSITORY_OPTIONS = {"-C", "--git-dir", "--work-tree"}


def expand_repository_options(prefix):
    """Apply the shell's unquoted leading-tilde expansion to Git targets."""
    expanded = []
    for index, value in enumerate(prefix):
        option = prefix[index - 1] if index else ""
        if option in REPOSITORY_OPTIONS and value.startswith("~"):
            value = os.path.expanduser(value)
        else:
            name, separator, target = value.partition("=")
            if separator and name in REPOSITORY_OPTIONS and target.startswith("~"):
                value = f"{name}={os.path.expanduser(target)}"
        expanded.append(value)
    return expanded


def command_invocations(command, argv_json):
    """Parse a shell command and/or a JSON argv into literal invocations."""
    invocations = _shell_invocations(command) if command else []
    if argv_json:
        argv = json.loads(argv_json)
        if not isinstance(argv, list) or not all(isinstance(v, str) for v in argv):
            raise ValueError("invalid-command-argv")
        invocations.append(argv)
    return invocations


def command_targets(cwd, command, argv_json, git_directory):
    """Resolve literal command declarations, never infer process cwd ownership."""
    targets = {cwd}
    for argv in command_invocations(command, argv_json):
        if not argv or Path(argv[0]).name != "git":
            continue
        prefix, effective, verb, _ = split_invocation(argv[1:], str(cwd))
        if not prefix or not verb:
            continue
        # The runtime shell expands `git -C ~/repo`; resolve the same target.
        prefix = expand_repository_options(prefix)
        common, directory, top = _git_repo_identity(real_git(), effective, prefix)
        if not all((common, directory, top)) or not Path(top).is_absolute():
            raise ValueError("git-target-unavailable")
        target = Path(top)
        if (Path(common).resolve() != Path(directory).resolve()
                and git_directory(target) != Path(directory).resolve()):
            raise ValueError("inconsistent-git-target")
        targets.add(target)
    return targets
