#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shell and builtin launcher option parsing."""

from __future__ import annotations

from command_policy_dispatch import CommandParseError
from command_policy_wrapper_options import _consume_option


def _shell_command_index(argv: list[str]) -> int | None:
    index = 1
    value_options = {"-O", "+O", "-o", "+o", "--init-file", "--rcfile"}
    while index < len(argv):
        arg = argv[index]
        command_index = _shell_command_option_index(arg, index)
        if command_index is not False:
            return command_index
        if arg in {"--init-file", "--rcfile"} or arg.startswith(("--init-file=", "--rcfile=")):
            raise CommandParseError(f"shell startup file option is unsupported: {arg}")
        consumed = _shell_value_option_index(argv, index, value_options)
        if consumed is not None:
            index = consumed
            continue
        index += 1
    return None


def _shell_command_option_index(arg: str, index: int) -> int | None | bool:
    if arg == "--":
        return None
    if arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]:
        return index + 1
    if not arg.startswith(("-", "+")):
        return None
    return False


def _shell_value_option_index(
    argv: list[str], index: int, value_options: set[str]
) -> int | None:
    arg = argv[index]
    if arg in value_options:
        if index + 1 >= len(argv):
            raise CommandParseError(f"missing value for shell option {arg}")
        return index + 2
    if any(
        arg.startswith(option + "=")
        for option in value_options
        if option.startswith("--")
    ):
        return index + 1
    return None


def _unwrap_exec(argv: list[str]) -> list[str]:
    index = 1
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, {"-a"}, {"-c", "-l"})
    if index >= len(argv):
        raise CommandParseError("exec wrapper has no command")
    return argv[index:]


def _unwrap_command(argv: list[str]) -> list[str]:
    index = 1
    while index < len(argv) and argv[index] in {"-p", "--"}:
        index += 1
    if index >= len(argv):
        raise CommandParseError("command wrapper has no command")
    return argv[index:]
