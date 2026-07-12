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
    _validate_command_text(command)
    quote_state = (False, False, False)
    index = 0
    while index < len(command):
        char = command[index]
        next_char = command[index + 1] if index + 1 < len(command) else ""
        single, double, escaped, consumed = _shell_quote_state(char, *quote_state)
        quote_state = (single, double, escaped)
        if consumed or single:
            index += 1
            continue
        _validate_shell_character(command, index, char, next_char, double)
        index += 1
    if any(quote_state):
        raise CommandParseError("unterminated shell quoting or escape")


def _validate_command_text(command: str) -> None:
    if not command.strip():
        raise CommandParseError("command is empty")
    if "\n" in command or "\r" in command:
        raise CommandParseError("multiline shell commands are unsupported")


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
    if double:
        if char in {"`", "$"}:
            raise CommandParseError("dynamic shell expansion is unsupported")
        return
    _validate_unquoted_character(command, index, char, next_char)


def _validate_unquoted_character(
    command: str, index: int, char: str, next_char: str
) -> None:
    invalid = {
        "`": "dynamic shell expansion is unsupported",
        "$": "dynamic shell expansion is unsupported",
        "<": "shell redirection is unsupported",
        ">": "shell redirection is unsupported",
        "(": "shell grouping and subshell syntax are unsupported",
        ")": "shell grouping and subshell syntax are unsupported",
        "{": "shell grouping and subshell syntax are unsupported",
        "}": "shell grouping and subshell syntax are unsupported",
        "*": "unquoted shell glob syntax is unsupported",
        "[": "unquoted shell glob syntax is unsupported",
    }
    if char in invalid:
        raise CommandParseError(invalid[char])
    if char == "&" and next_char != "&" and (index == 0 or command[index - 1] != "&"):
        raise CommandParseError("background shell execution is unsupported")


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
    invocations, segment = _expand_shell_tokens(tokens)
    if not segment:
        raise CommandParseError("shell command ends with an operator")
    invocations.extend(_expand_argv(segment))
    if not invocations:
        raise CommandParseError("command produced no executable argv")
    return invocations


def _expand_shell_tokens(tokens: list[str]) -> tuple[list[list[str]], list[str]]:
    invocations: list[list[str]] = []
    segment: list[str] = []
    for token in tokens:
        if token in SHELL_OPERATORS:
            if not segment:
                raise CommandParseError("empty or repeated shell operator segment")
            invocations.extend(_expand_argv(segment))
            segment = []
        elif token and all(char in ";&|()" for char in token):
            raise CommandParseError(f"unsupported shell operator {token}")
        else:
            segment.append(token)
    return invocations, segment
