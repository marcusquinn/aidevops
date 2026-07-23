#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Parse Git global options and repository targets for canonical policy."""

from __future__ import annotations

GLOBAL_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}


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
