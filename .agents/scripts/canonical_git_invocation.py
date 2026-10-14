#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Parse Git global options and repository targets for canonical policy."""

from __future__ import annotations

from collections.abc import Iterator

GLOBAL_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
CLONE_VALUE_OPTIONS = {
        "--origin", "-o", "--branch", "-b", "--depth", "--shallow-since",
        "--shallow-exclude", "--reference", "--reference-if-able", "--filter",
        "--jobs", "-j", "--server-option", "--separate-git-dir", "--template",
}
CLONE_FLAG_OPTIONS = {
        "--local", "-l", "--no-local", "--no-hardlinks", "--shared", "-s",
        "--quiet", "-q", "--verbose", "-v", "--progress", "--no-checkout", "-n",
        "--bare", "--mirror", "--single-branch", "--no-single-branch", "--no-tags",
        "--shallow-submodules", "--no-shallow-submodules", "--sparse", "--dissociate",
        "--remote-submodules", "--no-remote-submodules", "--reject-shallow",
        "--no-reject-shallow", "--also-filter-submodules", "--recurse-submodules",
}


def _clone_option(arg: str, remaining: Iterator[str]) -> tuple[bool, str]:
    """Consume a known option and return any auxiliary filesystem path."""
    option, separator, value = arg.partition("=")
    if option not in CLONE_VALUE_OPTIONS:
        return arg in CLONE_FLAG_OPTIONS or arg.startswith("--recurse-submodules="), ""
    if not separator:
        value = next(remaining, "")
    if not value:
        return False, ""
    auxiliary = value if option in {"--separate-git-dir", "--template"} else ""
    return True, auxiliary


def clone_paths(args: list[str]) -> tuple[str, list[str]]:
    """Parse an explicit destination, failing closed on unknown clone options."""
    positional: list[str] = []
    auxiliary: list[str] = []
    terminated = False
    remaining = iter(args)
    for arg in remaining:
        if not terminated and arg == "--":
            terminated = True
        elif not terminated and arg.startswith("-"):
            valid, path = _clone_option(arg, remaining)
            if not valid:
                return "", []
            if path:
                auxiliary.append(path)
        else:
            positional.append(arg)
    return (positional[1], auxiliary) if len(positional) == 2 else ("", [])


def is_version_query(argv: list[str]) -> bool:
    """Accept only a version flag, optionally preceded by exact -C pairs."""
    index = 0
    while index + 1 < len(argv) and argv[index] == "-C":
        index += 2
    return argv[index:] in (["--version"], ["-v"])


def split_invocation(
    argv: list[str], base_cwd: str
) -> tuple[list[str], str, str, list[str]]:
    prefix: list[str] = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            index += 1
            break
        if arg in GLOBAL_VALUE_OPTIONS:
            if index + 1 >= len(argv):
                return prefix, base_cwd, "", []
            prefix.extend([arg, argv[index + 1]])
            index += 2
            continue
        # Version flags terminate Git's global-option handling. Do not let them
        # contaminate repository probes for a purported trailing subcommand.
        if arg in {"--version", "-v"}:
            return prefix, base_cwd, "", argv[index:]
        if arg.startswith("-"):
            prefix.append(arg)
            index += 1
            continue
        return prefix, base_cwd, arg, argv[index + 1 :]
    return prefix, base_cwd, "", argv[index:]


def repository_values(prefix: list[str]) -> list[str]:
    values = [
        prefix[index + 1]
        for index, option in enumerate(prefix[:-1])
        if option in {"-C", "--git-dir", "--work-tree"}
    ]
    values.extend(
        value.split("=", 1)[1]
        for value in prefix
        if value.startswith(("--git-dir=", "--work-tree="))
    )
    return values
