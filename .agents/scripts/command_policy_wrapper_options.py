#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Option and environment handling for deterministic command wrappers."""

from __future__ import annotations

import re

from command_policy_dispatch import CommandParseError


def _consume_option(
    argv: list[str], index: int, value_options: set[str], flag_options: set[str]
) -> int:
    arg = argv[index]
    if arg == "--":
        return index + 1
    if arg in value_options:
        if index + 1 >= len(argv):
            raise CommandParseError(f"missing value for wrapper option {arg}")
        return index + 2
    if _is_attached_value_option(arg, value_options):
        return index + 1
    if arg in flag_options:
        return index + 1
    if _is_combined_short_flags(arg, flag_options):
        return index + 1
    raise CommandParseError(f"unsupported wrapper option {arg}")


def _is_attached_value_option(arg: str, value_options: set[str]) -> bool:
    long_attached = any(
        arg.startswith(option + "=") for option in value_options if option.startswith("--")
    )
    short_attached = any(
        arg.startswith(option) and arg != option
        for option in value_options
        if option.startswith("-") and not option.startswith("--")
    )
    return long_attached or short_attached


def _is_combined_short_flags(arg: str, flag_options: set[str]) -> bool:
    short_flags = {
        option[1:] for option in flag_options if re.fullmatch(r"-[A-Za-z0-9]", option)
    }
    return (
        arg.startswith("-")
        and not arg.startswith("--")
        and set(arg[1:]).issubset(short_flags)
    )


def _unwrap_env(argv: list[str]) -> list[str]:
    index = 1
    values = {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}
    flags = {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug"}
    while index < len(argv) and argv[index].startswith("-"):
        option = argv[index]
        if option in {"-C", "--chdir", "-S", "--split-string"} or option.startswith(("-C", "-S", "--chdir=", "--split-string=")):
            raise CommandParseError(f"env option changes command interpretation and is unsupported: {option}")
        index = _consume_option(argv, index, values, flags)
    index = _environment_command_index(argv, index)
    if index >= len(argv):
        raise CommandParseError("env wrapper has no command")
    return argv[index:]


def _environment_command_index(argv: list[str], index: int) -> int:
    while index < len(argv) and "=" in argv[index] and not argv[index].startswith("="):
        name = argv[index].split("=", 1)[0]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            break
        if _is_safety_sensitive_assignment(name):
            raise CommandParseError(
                f"safety-affecting environment assignment is unsupported: {name}"
            )
        index += 1
    return index


def _unwrap_sudo(argv: list[str]) -> list[str]:
    index = 1
    values = {
        "-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
        "-C", "--close-from", "-T", "--command-timeout", "-R", "--chroot",
        "-D", "--chdir",
    }
    flags = {
        "-A", "--askpass", "-b", "--background", "-E", "--preserve-env",
        "-H", "--set-home", "-n", "--non-interactive", "-P", "--preserve-groups",
        "-S", "--stdin", "-i", "--login", "-s", "--shell", "-k", "-K", "-v",
    }
    while index < len(argv) and argv[index].startswith("-"):
        option = argv[index]
        if option in {"-D", "--chdir", "-R", "--chroot"} or option.startswith(("-D", "-R", "--chdir=", "--chroot=")):
            raise CommandParseError(f"sudo option changes command location and is unsupported: {option}")
        index = _consume_option(argv, index, values, flags)
    if index >= len(argv):
        raise CommandParseError("sudo wrapper has no command")
    return argv[index:]


def _unwrap_time(argv: list[str]) -> list[str]:
    index = 1
    values = {"-f", "--format", "-o", "--output"}
    flags = {"-a", "--append", "-p", "--portability", "-v", "--verbose", "-q", "--quiet"}
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, values, flags)
    if index >= len(argv):
        raise CommandParseError("time wrapper has no command")
    return argv[index:]


def _is_safety_sensitive_assignment(name: str) -> bool:
    upper = name.upper()
    return upper.endswith("_PROXY") or upper.startswith("GIT_CONFIG_") or upper in {
        "AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION",
        "AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT",
        "ALL_PROXY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
        "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_EXEC_PATH", "GIT_OBJECT_DIRECTORY",
        "GIT_PROXY_COMMAND", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_WORK_TREE",
        "CURL_HOME", "WGETRC", "BASH_ENV", "ENV", "ZDOTDIR", "GH_CONFIG_DIR",
        "GH_ENTERPRISE_TOKEN", "GH_HOST", "GH_REPO", "GH_TOKEN", "GITHUB_TOKEN",
    }


def _strip_leading_assignments(argv: list[str]) -> list[str]:
    index = 0
    while index < len(argv) and "=" in argv[index]:
        name = argv[index].split("=", 1)[0]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            break
        if _is_safety_sensitive_assignment(name):
            raise CommandParseError(f"safety-affecting environment assignment is unsupported: {name}")
        index += 1
    if index >= len(argv):
        raise CommandParseError("environment assignment has no command")
    return argv[index:]
