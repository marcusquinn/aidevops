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
# shlex drops quote provenance, so any quoted or escaped tilde in the raw
# command keeps every target literal, exactly as the shell would pass it.
QUOTED_TILDE_MARKERS = ("'~", '"~', "\\~")
# Read-only inspection of a `-C/--git-dir/--work-tree` target admits no owner
# (GH#37022): admission precedes a worktree write, and an inspecting session
# must not become the live owner that blocks its own retirement. The allowlist
# is closed; any other verb, global option, or output-writing flag admits.
# #aidevops:trust-boundary — the tool workdir target is always admitted.
READ_ONLY_VERBS = {"status", "log", "diff", "show", "rev-parse", "ls-files", "for-each-ref"}
READ_ONLY_PREFIX_FLAGS = {"--no-pager", "--no-optional-locks", "-P"}
BRANCH_LIST_FLAGS = {"--list", "-l", "--show-current"}
BRANCH_MUTATING_FLAGS = {
    "-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
    "-f", "--force", "-u", "--set-upstream-to", "--unset-upstream",
    "--edit-description", "-t", "--track", "--no-track",
}


def _read_only_prefix(prefix):
    """Only repository selectors and pager/lock flags; `-c` etc. still admit."""
    index = 0
    while index < len(prefix):
        option = prefix[index]
        if option in REPOSITORY_OPTIONS:
            index += 2
            continue
        if option.startswith(("--git-dir=", "--work-tree=")) or option in READ_ONLY_PREFIX_FLAGS:
            index += 1
            continue
        return False
    return True


def _branch_lists_only(rest):
    """`git branch --list|-l|--show-current` with no mutating flag anywhere."""
    return (rest[:1] != [] and rest[0] in BRANCH_LIST_FLAGS
            and not any(arg.split("=", 1)[0] in BRANCH_MUTATING_FLAGS for arg in rest))


# Verbs whose read-only status depends on their subcommand or flags.
SUBCOMMAND_CHECKS = {
    "worktree": lambda rest: rest[:1] == ["list"],
    "branch": _branch_lists_only,
}


def is_read_only_invocation(prefix, verb, rest):
    """True only for a closed set of inspection commands that write no tree."""
    writes_output = any(arg == "-o" or arg.startswith("--output") for arg in rest)
    if writes_output or not _read_only_prefix(prefix):
        return False
    check = SUBCOMMAND_CHECKS.get(verb)
    return verb in READ_ONLY_VERBS or bool(check and check(rest))


def expand_repository_options(prefix):
    """Apply the shell's unquoted leading-tilde expansion to Git targets.

    Only a separate option value is expanded: neither bash nor zsh (without
    MAGIC_EQUAL_SUBST) expands `--git-dir=~/x`, so that form stays literal.
    """
    expanded = []
    for index, value in enumerate(prefix):
        option = prefix[index - 1] if index else ""
        if option in REPOSITORY_OPTIONS and value.startswith("~"):
            value = os.path.expanduser(value)
        expanded.append(value)
    return expanded


def command_invocations(command, argv_json):
    """Return (argv, shell_expands_tilde) pairs for declared invocations."""
    invocations = []
    if command:
        expands = not any(marker in command for marker in QUOTED_TILDE_MARKERS)
        invocations = [(argv, expands) for argv in _shell_invocations(command)]
    if argv_json:
        argv = json.loads(argv_json)
        if not isinstance(argv, list) or not all(isinstance(v, str) for v in argv):
            raise ValueError("invalid-command-argv")
        # Exec argv never passes through a shell: no tilde expansion.
        invocations.append((argv, False))
    return invocations


def command_targets(cwd, command, argv_json, git_directory):
    """Resolve literal command declarations, never infer process cwd ownership."""
    targets = {cwd}
    for argv, shell_expands_tilde in command_invocations(command, argv_json):
        if not argv or Path(argv[0]).name != "git":
            continue
        prefix, effective, verb, rest = split_invocation(argv[1:], str(cwd))
        if not prefix or not verb or is_read_only_invocation(prefix, verb, rest):
            continue
        # The runtime shell expands unquoted `git -C ~/repo`; resolve the same target.
        if shell_expands_tilde:
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
