#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only classification for canonical `git config` invocations."""

from __future__ import annotations

_READ_FLAGS = {
    "--get",
    "--get-all",
    "--get-regexp",
    "--get-urlmatch",
    "--list",
    "-l",
    "--show-origin",
    "--show-scope",
    "--name-only",
    "--includes",
    "--null",
    "-z",
}
_WRITE_FLAGS = {
    "--add",
    "--unset",
    "--unset-all",
    "--rename-section",
    "--remove-section",
    "--replace-all",
    "--edit",
    "-e",
}

# GH#33066: options that never write when combined with a single-key read.
_VALUE_OPTIONS = {"--type", "--file", "-f", "--blob", "--default"}
_VALUE_OPTION_PREFIXES = ("--type=", "--file=", "--blob=", "--default=")
_NEUTRAL_OPTIONS = {
    "--global",
    "--system",
    "--local",
    "--worktree",
    "--includes",
    "--no-includes",
    "--null",
    "-z",
    "--show-origin",
    "--show-scope",
    "--name-only",
    "--bool",
    "--int",
    "--bool-or-int",
    "--path",
    "--expiry-date",
    "--no-type",
}
# Only valid after the Git 2.46+ `get` subcommand.
_GET_OPTIONS = {"--all", "--regexp", "--fixed-value", "--show-names"}
_GET_OPTION_PREFIXES = ("--value=", "--url=")
# Read subcommand -> number of positionals it takes after itself.
_READ_SUBCOMMANDS = {"get": 1, "list": 0}


def config_is_read_only(args: list[str]) -> bool:
    return (
        _is_allowed_global_auth_write(args)
        or _is_bare_read(args)
        or (
            bool(args)
            and any(arg in _READ_FLAGS for arg in args)
            and not any(arg in _WRITE_FLAGS for arg in args)
        )
    )


def _read_positionals(args: list[str]) -> tuple[list[str], bool] | None:
    """Return (positionals, saw_get_option), or None for unknown/write options.

    Fail closed: any option not known to be read-neutral (including every write
    flag and `-e`) rejects the command, and a value option missing its value is
    rejected rather than guessed.
    """
    positionals: list[str] = []
    saw_get_option = False
    expect_value = False
    for arg in args:
        if expect_value:
            expect_value = False
        elif arg in _VALUE_OPTIONS:
            expect_value = True
        elif arg in _NEUTRAL_OPTIONS or arg.startswith(_VALUE_OPTION_PREFIXES):
            continue
        elif arg in _GET_OPTIONS or arg.startswith(_GET_OPTION_PREFIXES):
            saw_get_option = True
        elif arg.startswith("-"):
            return None
        else:
            positionals.append(arg)
    if expect_value:
        return None
    return positionals, saw_get_option


def _is_bare_read(args: list[str]) -> bool:
    """Allow `git config [scope] <section.key>` and `git config get|list`.

    A single positional key is a read; a second positional is a value (write).
    Keys must contain a section separator so write subcommands such as `set`
    can never be mistaken for a legacy key read.
    """
    parsed = _read_positionals(args)
    if parsed is None or not parsed[0]:
        return False
    positionals, saw_get_option = parsed
    head = positionals[0]
    if head in _READ_SUBCOMMANDS:
        get_options_valid = head == "get" or not saw_get_option
        return get_options_valid and len(positionals) - 1 == _READ_SUBCOMMANDS[head]
    return not saw_get_option and len(positionals) == 1 and "." in head


def _is_allowed_global_auth_write(args: list[str]) -> bool:
    """Allow GitHub CLI auth setup to update user-scoped credential config.

    The canonical guard protects repository worktrees. A `gh auth refresh` or
    `gh auth setup-git` may run while the shell happens to be inside a canonical
    checkout, but its intended mutation is `~/.gitconfig`, not the repository.
    Keep this narrow: only explicit user-scope writes to credential helper keys
    are allowed; repo-local config writes remain blocked.
    """
    destructive_writes = {"--unset", "--unset-all", "--remove-section", "--rename-section"}
    keys = _write_keys(args)
    key = keys[0]
    credential_key = key == "credential.helper" or (
        key.startswith("credential.") and key.endswith(".helper")
    )
    user_scoped = any(arg in {"--global", "--user"} for arg in args)
    repo_scoped = any(arg in {"--local", "--worktree", "--file", "-f"} for arg in args)
    alternate_source = any(arg.startswith(("--file=", "--blob=")) for arg in args)
    destructive = any(arg in destructive_writes for arg in args)
    return all(
        (
            args,
            user_scoped,
            not repo_scoped,
            not alternate_source,
            not destructive,
            key,
            credential_key,
        )
    )


def _write_keys(args: list[str]) -> list[str]:
    value_options = {"--type", "--fixed-value"}
    ignored_flags = {"--global", "--user", "--add", "--replace-all"}
    keys: list[str] = []
    skip_next = False
    invalid = False
    for arg in args:
        if skip_next:
            skip_next = False
        elif arg in value_options:
            skip_next = True
        elif arg.startswith("--") or arg in ignored_flags:
            continue
        elif arg.startswith("-"):
            invalid = True
            break
        else:
            keys.append(arg)
    return keys if not invalid and keys else [""]
