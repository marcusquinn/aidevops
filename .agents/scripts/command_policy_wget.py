#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""wget destination analysis for command-policy-helper.py."""

from __future__ import annotations

import re
from typing import Any

from command_policy_http import _option_value
from command_policy_network import _add_destination


def _analyze_wget(argv: list[str], result: dict[str, Any]) -> None:
    index = 1
    value_options = {
        "-O", "--output-document", "-o", "--output-file", "-a", "--append-output",
        "-P", "--directory-prefix", "--header", "--user", "--password", "--timeout",
        "--tries", "--wait", "--user-agent", "--referer",
    }
    short_value_options = {"-O", "-o", "-a", "-P", "-U", "-t", "-T", "-w"}
    while index < len(argv):
        index = _wget_arg(argv, index, result, value_options, short_value_options)


def _wget_arg(
    argv: list[str], index: int, result: dict[str, Any],
    value_options: set[str], short_value_options: set[str],
) -> int:
    arg = argv[index]
    option = arg.split("=", 1)[0]
    next_index = index + 1
    if option == "--proxy":
        value, next_index = _option_value(argv, index)
        _add_destination(result, value or "", "proxy")
    elif option in {"-e", "--execute"}:
        next_index = _wget_execute_option(argv, index, result)
    elif option in {"-i", "--input-file"}:
        result["unclassified"].append("wget-input-file")
        next_index = _wget_input_file_index(arg, option, index)
    elif option in value_options:
        next_index = _option_value(argv, index)[1]
    elif arg in short_value_options:
        next_index = min(index + 2, len(argv))
    elif not arg.startswith("-"):
        _add_destination(result, arg, "url")
    return next_index


def _wget_input_file_index(arg: str, option: str, index: int) -> int:
    return index + (2 if arg == option and "=" not in arg else 1)


def _wget_execute_option(argv: list[str], index: int, result: dict[str, Any]) -> int:
    value, next_index = _option_value(argv, index)
    match = re.match(r"(?i)^(?:https?|ftp)_proxy=(.+)$", value or "")
    if match:
        _add_destination(result, match.group(1), "proxy")
    elif value and "proxy" not in value.lower():
        result["unclassified"].append(f"wget-execute:{value}")
    return next_index
