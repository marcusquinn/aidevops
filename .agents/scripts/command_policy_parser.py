#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic parsing of the supported shell-command subset."""

from __future__ import annotations

import shlex

from command_policy_dispatch import CommandParseError
from command_policy_wrappers import _expand_argv as _expand_wrapped_argv

SHELL_OPERATORS = {"&&", "||", ";", "|"}


def _scan_supported_shell(command: str) -> None:
    if not command.strip():
        raise CommandParseError("command is empty")
    if "\n" in command or "\r" in command:
        raise CommandParseError("multiline shell commands are unsupported")
    single = False
    double = False
    escaped = False
    index = 0
    while index < len(command):
        char = command[index]
        next_char = command[index + 1] if index + 1 < len(command) else ""
        single, double, escaped, consumed = _shell_quote_state(
            char, single, double, escaped
        )
        if consumed or single:
            index += 1
            continue
        _validate_shell_character(command, index, char, next_char, double)
        index += 1
    if single or double or escaped:
        raise CommandParseError("unterminated shell quoting or escape")


def _shell_quote_state(
    char: str, single: bool, double: bool, escaped: bool
) -> tuple[bool, bool, bool, bool]:
    if escaped:
        return single, double, False, True
    if char == "\\" and not single:
        return single, double, True, True
    if char == "'" and not double:
        return not single, double, False, True
    if char == '"' and not single:
        return single, not double, False, True
    return single, double, False, False


def _validate_shell_character(
    command: str, index: int, char: str, next_char: str, double: bool
) -> None:
    if char in {"`", "$"}:
        raise CommandParseError("dynamic shell expansion is unsupported")
    if double:
        return
    if char in "<>":
        raise CommandParseError("shell redirection is unsupported")
    if char in "(){}":
        raise CommandParseError("shell grouping and subshell syntax are unsupported")
    if char == "&" and next_char != "&" and (index == 0 or command[index - 1] != "&"):
        raise CommandParseError("background shell execution is unsupported")
    if char in "*[":
        raise CommandParseError("unquoted shell glob syntax is unsupported")


def _expand_argv(argv: list[str]) -> list[list[str]]:
    return _expand_wrapped_argv(argv, _shell_invocations)


def _shell_invocations(command: str) -> list[list[str]]:
    _scan_supported_shell(command)
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError as exc:
        raise CommandParseError(f"unable to tokenize shell command: {exc}") from exc
    invocations: list[list[str]] = []
    segment: list[str] = []
    expect_command = True
    for token in tokens:
        if token in SHELL_OPERATORS:
            if expect_command or not segment:
                raise CommandParseError("empty or repeated shell operator segment")
            invocations.extend(_expand_argv(segment))
            segment = []
            expect_command = True
            continue
        if token and all(char in ";&|()" for char in token):
            raise CommandParseError(f"unsupported shell operator {token}")
        segment.append(token)
        expect_command = False
    if not segment:
        raise CommandParseError("shell command ends with an operator")
    invocations.extend(_expand_argv(segment))
    if not invocations:
        raise CommandParseError("command produced no executable argv")
    return invocations
