#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Worker-only guard against disabling or redirecting Git commit signing.

GH#33065: headless workers that could not sign "succeeded" by running
`git -c commit.gpgsign=false commit` or `git commit --no-gpg-sign`, creating
unsigned history and hiding the real setup defect. Workers must stop with the
signing blocker instead.

Scope is the model's direct argv only. Framework scripts that create internal
unsigned commits run below this layer and are unaffected. Command-local
GIT_CONFIG_* assignments are already rejected by the shared parser
(`_is_safety_sensitive_assignment`); previously exported shell state is a
known residual gap outside argv policy.
"""

from __future__ import annotations

import os
from typing import Any

from command_policy_config import _decision

_DECISION_ID = "git.worker-signing-override"
_GUIDANCE = (
    "Workers must not disable or redirect commit signing. If signing fails, stop "
    "and report the signing blocker; the operator runs 'aidevops signing "
    "headless-setup' in a terminal."
)
_FALSE_VALUES = {"false", "no", "off", "0", ""}
_TRUE_VALUES = {"true", "yes", "on", "1"}
_SIGN_TOGGLE_KEYS = {"commit.gpgsign", "tag.gpgsign", "push.gpgsign"}
_SIGNER_KEYS = {"user.signingkey"}
_SIGNER_SECTION = "gpg."
_GLOBAL_VALUE_OPTIONS = {"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
_NO_SIGN_OPTION = "--no-gpg-sign"
# Shortest unambiguous-enough prefix; Git accepts abbreviated long options.
_NO_SIGN_MIN_PREFIX = len("--no-g")
_NO_SIGN_SUBCOMMANDS = {
    "commit",
    "commit-tree",
    "merge",
    "pull",
    "rebase",
    "cherry-pick",
    "revert",
    "am",
    "stash",
}
_CONFIG_WRITE_FLAGS = {
    "--add",
    "--replace-all",
    "--unset",
    "--unset-all",
    "--rename-section",
    "--remove-section",
    "--edit",
    "-e",
}
_CONFIG_WRITE_SUBCOMMANDS = {"set", "unset", "rename-section", "remove-section", "edit"}
_CONFIG_VALUE_OPTIONS = {"--type", "--file", "-f", "--blob", "--default", "--comment", "--value"}
_SIGNING_SECTIONS = {"gpg", "commit", "tag", "user", "push"}
_CONFIG_SECTION_FLAGS = {"rename-section", "remove-section", "--rename-section", "--remove-section"}
_CONFIG_UNSET_FLAGS = {"unset", "--unset", "--unset-all"}


def evaluate_worker_signing(invocations: list[list[str]]) -> dict[str, Any]:
    for argv in invocations:
        detail = _signing_override(argv)
        if detail:
            return _decision("forbid", _DECISION_ID, f"{_GUIDANCE} Blocked: {detail}.")
    return _decision("allow", "git.worker-signing-allow", "No signing override detected")


def _signing_override(argv: list[str]) -> str:
    if not argv or os.path.basename(argv[0]) != "git":
        return ""
    config_pairs, subcommand, args = _split_global_options(argv[1:])
    detail = next(
        (f"git -c {key}" for key, value in config_pairs if _disables_signing(key, value)),
        "",
    )
    return detail or _subcommand_override(subcommand, args)


def _subcommand_override(subcommand: str, args: list[str]) -> str:
    if subcommand == "config":
        return _config_write_override(args)
    if subcommand == "tag":
        option = "--no-sign"
        blocked = option in _option_region(args)
    else:
        option = _NO_SIGN_OPTION
        blocked = subcommand in _NO_SIGN_SUBCOMMANDS and _has_no_sign_option(args)
    return f"git {subcommand} {option}" if blocked else ""


def _split_global_options(
    args: list[str],
) -> tuple[list[tuple[str, str | None]], str, list[str]]:
    """Return (-c key/value pairs, subcommand, subcommand args).

    A value of None means the value is not visible in argv (--config-env) and
    must be treated as a potential override.
    """
    pairs: list[tuple[str, str | None]] = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-c", "--config-env"} and index + 1 < len(args):
            pairs.append(_config_pair(args[index + 1], arg == "--config-env"))
            index += 2
        elif arg.startswith("--config-env="):
            pairs.append(_config_pair(arg.split("=", 1)[1], True))
            index += 1
        elif arg in _GLOBAL_VALUE_OPTIONS:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return pairs, arg, args[index + 1 :]
    return pairs, "", []


def _config_pair(assignment: str, from_env: bool) -> tuple[str, str | None]:
    key, separator, value = assignment.partition("=")
    if from_env:
        return key.lower(), None
    # `-c key` without `=` sets the key to true.
    return key.lower(), value if separator else "true"


def _disables_signing(key: str, value: str | None) -> bool:
    if key.startswith(_SIGNER_SECTION) or key in _SIGNER_KEYS:
        return True
    if key in _SIGN_TOGGLE_KEYS:
        return value is None or value.strip().lower() not in _TRUE_VALUES
    return False


def _option_region(args: list[str]) -> list[str]:
    return args[: args.index("--")] if "--" in args else args


def _has_no_sign_option(args: list[str]) -> bool:
    for arg in _option_region(args):
        name = arg.split("=", 1)[0]
        if len(name) >= _NO_SIGN_MIN_PREFIX and _NO_SIGN_OPTION.startswith(name):
            return True
    return False


def _config_write_override(args: list[str]) -> str:
    positionals, write_flags = _config_positionals(args)
    head = positionals[0] if positionals else ""
    if head in _CONFIG_WRITE_SUBCOMMANDS:
        write_flags.add(head)
        positionals = positionals[1:]
    elif head in {"get", "list"}:
        positionals = []
    if not positionals:
        return ""
    if write_flags & _CONFIG_SECTION_FLAGS:
        return _config_section_override(positionals[0])
    return _config_key_override(positionals, write_flags)


def _config_section_override(name: str) -> str:
    section = name.split(".", 1)[0].lower()
    return f"git config section {name}" if section in _SIGNING_SECTIONS else ""


def _config_key_override(positionals: list[str], write_flags: set[str]) -> str:
    key = positionals[0].lower()
    value = positionals[1] if len(positionals) > 1 else None
    signing_key = key in _SIGN_TOGGLE_KEYS or key in _SIGNER_KEYS or key.startswith(_SIGNER_SECTION)
    is_write = bool(write_flags) or value is not None
    unset = bool(write_flags & _CONFIG_UNSET_FLAGS)
    blocked = signing_key and is_write and (unset or _disables_signing(key, value))
    return f"git config {key}" if blocked else ""


def _config_positionals(args: list[str]) -> tuple[list[str], set[str]]:
    positionals: list[str] = []
    write_flags: set[str] = set()
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
        elif arg in _CONFIG_VALUE_OPTIONS:
            skip_next = True
        elif arg in _CONFIG_WRITE_FLAGS:
            write_flags.add(arg)
        elif not arg.startswith("-"):
            positionals.append(arg)
    return positionals, write_flags
