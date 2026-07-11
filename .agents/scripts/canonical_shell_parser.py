#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract Git argv vectors and effective directories from shell commands."""

from __future__ import annotations

import os
import shlex
from typing import Optional

SHELL_OPERATORS = {"&&", "||", ";", "|", "(", ")", "&"}
WRAPPERS = {"command", "sudo", "time", "nohup"}
REPOSITORY_ENVIRONMENT = {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}


def _shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def _assignment_name(token: str) -> str:
    if "=" not in token or token.startswith("-"):
        return ""
    return token.split("=", 1)[0]


def _skip_assignments(segment: list[str], start: int) -> int:
    index = start
    while index < len(segment):
        variable_name = _assignment_name(segment[index])
        if not variable_name:
            break
        if variable_name in REPOSITORY_ENVIRONMENT:
            raise PermissionError("Git repository environment override")
        index += 1
    return index


def _command_index(segment: list[str]) -> int:
    index = 0
    while index < len(segment):
        assignments_end = _skip_assignments(segment, index)
        if assignments_end != index:
            index = assignments_end
            continue
        if segment[index] in WRAPPERS:
            index += 1
            continue
        if segment[index] == "env":
            index = _skip_assignments(segment, index + 1)
            continue
        break
    return index


def _changed_directory(segment: list[str], cwd: str) -> str:
    target = os.path.expanduser(segment[1])
    return (
        target if os.path.isabs(target) else os.path.abspath(os.path.join(cwd, target))
    )


def _segment_invocation(
    segment: list[str], cwd: str
) -> tuple[Optional[list[str]], str]:
    if segment[0] == "cd" and len(segment) >= 2:
        return None, _changed_directory(segment, cwd)
    index = _command_index(segment)
    if index < len(segment) and os.path.basename(segment[index]) == "git":
        return segment[index + 1 :], cwd
    return None, cwd


def git_invocations(command: str, cwd: str) -> list[tuple[list[str], str]]:
    """Return each direct Git invocation and its effective working directory."""
    tokens = _shell_tokens(command)
    invocations: list[tuple[list[str], str]] = []
    segment: list[str] = []
    segment_cwd = cwd
    for token in tokens + [";"]:
        if token not in SHELL_OPERATORS:
            segment.append(token)
            continue
        if not segment:
            continue
        invocation, segment_cwd = _segment_invocation(segment, segment_cwd)
        if invocation is not None:
            invocations.append((invocation, segment_cwd))
        segment = []
    return invocations
