#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Argument-aware read-only checks for canonical Git operations."""

from __future__ import annotations

from typing import Callable

from canonical_git_ref_queries import REF_QUERY_CHECKS


def _branch_is_read_only(args: list[str]) -> bool:
    if not args:
        return True
    mutating = {
        "-d",
        "-D",
        "-m",
        "-M",
        "-c",
        "-C",
        "-f",
        "--delete",
        "--move",
        "--copy",
        "--force",
        "--edit-description",
        "--set-upstream-to",
        "--unset-upstream",
    }
    if any(
        arg in mutating or arg.startswith(("--move=", "--copy=", "--set-upstream-to="))
        for arg in args
    ):
        return False
    listing = any(
        arg in {"--list", "--contains", "--merged", "--no-merged", "--points-at"}
        or arg.startswith(("--contains=", "--merged=", "--no-merged=", "--points-at="))
        for arg in args
    )
    return listing or all(arg.startswith("-") or arg in {"HEAD", "@"} for arg in args)


def _config_is_read_only(args: list[str]) -> bool:
    read_flags = {
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
    write_flags = {
        "--add",
        "--unset",
        "--unset-all",
        "--rename-section",
        "--remove-section",
        "--replace-all",
        "--edit",
        "-e",
    }
    return (
        _config_is_allowed_global_auth_write(args)
        or _config_is_bare_read(args)
        or (
            bool(args)
            and any(arg in read_flags for arg in args)
            and not any(arg in write_flags for arg in args)
        )
    )


# GH#33066: options that never write when combined with a single-key read.
_CONFIG_VALUE_OPTIONS = {"--type", "--file", "-f", "--blob", "--default"}
_CONFIG_VALUE_OPTION_PREFIXES = ("--type=", "--file=", "--blob=", "--default=")
_CONFIG_NEUTRAL_OPTIONS = {
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
_CONFIG_GET_OPTIONS = {"--all", "--regexp", "--fixed-value", "--show-names"}
_CONFIG_GET_OPTION_PREFIXES = ("--value=", "--url=")
# Read subcommand -> number of positionals it takes after itself.
_CONFIG_READ_SUBCOMMANDS = {"get": 1, "list": 0}


def _config_read_positionals(args: list[str]) -> tuple[list[str], bool] | None:
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
        elif arg in _CONFIG_VALUE_OPTIONS:
            expect_value = True
        elif arg in _CONFIG_NEUTRAL_OPTIONS or arg.startswith(_CONFIG_VALUE_OPTION_PREFIXES):
            continue
        elif arg in _CONFIG_GET_OPTIONS or arg.startswith(_CONFIG_GET_OPTION_PREFIXES):
            saw_get_option = True
        elif arg.startswith("-"):
            return None
        else:
            positionals.append(arg)
    if expect_value:
        return None
    return positionals, saw_get_option


def _config_is_bare_read(args: list[str]) -> bool:
    """Allow `git config [scope] <section.key>` and `git config get|list`.

    A single positional key is a read; a second positional is a value (write).
    Keys must contain a section separator so write subcommands such as `set`
    can never be mistaken for a legacy key read.
    """
    parsed = _config_read_positionals(args)
    if parsed is None:
        return False
    positionals, saw_get_option = parsed
    if not positionals:
        return False
    head = positionals[0]
    if head in _CONFIG_READ_SUBCOMMANDS:
        if saw_get_option and head != "get":
            return False
        return len(positionals) - 1 == _CONFIG_READ_SUBCOMMANDS[head]
    return not saw_get_option and len(positionals) == 1 and "." in head


def _config_is_allowed_global_auth_write(args: list[str]) -> bool:
    """Allow GitHub CLI auth setup to update user-scoped credential config.

    The canonical guard protects repository worktrees. A `gh auth refresh` or
    `gh auth setup-git` may run while the shell happens to be inside a canonical
    checkout, but its intended mutation is `~/.gitconfig`, not the repository.
    Keep this narrow: only explicit user-scope writes to credential helper keys
    are allowed; repo-local config writes remain blocked.
    """
    destructive_writes = {"--unset", "--unset-all", "--remove-section", "--rename-section"}
    keys = _config_write_keys(args)
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


def _config_write_keys(args: list[str]) -> list[str]:
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


def _clean_is_read_only(args: list[str]) -> bool:
    return any(
        arg == "--dry-run"
        or (arg.startswith("-") and not arg.startswith("--") and "n" in arg[1:])
        for arg in args
    )


def _bundle_is_read_only(args: list[str]) -> bool:
    if not args or args[0] != "verify":
        return False
    bundle_args = args[1:]
    if not bundle_args:
        return False
    allowed_flags = {"-q", "--quiet"}
    paths = [arg for arg in bundle_args if arg not in allowed_flags]
    return len(paths) == 1 and not paths[0].startswith("-")


def _is_hash_object_write_flag(arg: str) -> bool:
    return arg == "-w" or (
        arg.startswith("-") and not arg.startswith("--") and "w" in arg[1:]
    )


def _hash_object_options(args: list[str]) -> list[str]:
    try:
        return args[: args.index("--")]
    except ValueError:
        return args


def _is_unknown_hash_object_option(arg: str) -> bool:
    read_only_options = {
        "--literally",
        "--no-filters",
        "--stdin",
        "--stdin-paths",
    }
    return (
        arg.startswith("-")
        and arg not in read_only_options
        and not arg.startswith("--path=")
    )


def _hash_object_is_read_only(args: list[str]) -> bool:
    """Allow hashing inputs while rejecting object database writes."""
    expect_value = False

    for arg in _hash_object_options(args):
        if expect_value:
            expect_value = False
            continue
        if arg == "-t":
            expect_value = True
            continue
        if _is_hash_object_write_flag(arg) or _is_unknown_hash_object_option(arg):
            return False

    return not expect_value


CANONICAL_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "branch": _branch_is_read_only,
    "bundle": _bundle_is_read_only,
    "config": _config_is_read_only,
    "clean": _clean_is_read_only,
    "hash-object": _hash_object_is_read_only,
    **REF_QUERY_CHECKS,
}
