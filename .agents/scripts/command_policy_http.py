#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""curl and wget destination analysis for command-policy-helper.py."""

from __future__ import annotations

import re
from typing import Any

from command_policy_network import _add_destination


def _option_value(argv: list[str], index: int) -> tuple[str | None, int]:
    if "=" in argv[index]:
        return argv[index].split("=", 1)[1], index + 1
    if index + 1 >= len(argv):
        return None, index + 1
    return argv[index + 1], index + 2


def _analyze_curl(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {
        "--request", "--header", "--data", "--data-raw", "--data-binary", "--form",
        "--user", "--output", "--referer", "--user-agent", "--cookie", "--cookie-jar",
        "--cacert", "--cert", "--key", "--max-time", "--connect-timeout", "--retry",
        "--proto", "--proto-redir", "--interface", "--dns-interface", "--dns-ipv4-addr",
        "--dns-ipv6-addr",
    }
    destination_options = {"--url", "--proxy", "--preproxy"}
    short_value_options = {
        "-A",
        "-b",
        "-c",
        "-d",
        "-D",
        "-e",
        "-E",
        "-F",
        "-H",
        "-K",
        "-m",
        "-o",
        "-Q",
        "-r",
        "-T",
        "-u",
        "-w",
        "-X",
        "-Y",
        "-z",
    }
    index = 1
    while index < len(argv):
        special_index = _curl_destination_option(argv, index, result, destination_options)
        index = special_index if special_index is not None else _curl_other_arg(
            argv, index, result, value_options, short_value_options
        )


def _curl_destination_option(
    argv: list[str], index: int, result: dict[str, Any], destination_options: set[str]
) -> int | None:
    option = argv[index].split("=", 1)[0]
    if option in destination_options:
        value, next_index = _option_value(argv, index)
        if value is None:
            result["unclassified"].append(f"missing:{option}")
        else:
            _add_destination(result, value, option)
        return next_index
    if option == "--resolve":
        return _curl_resolve_option(argv, index, result)
    if option == "--connect-to":
        return _curl_connect_option(argv, index, result)
    return None


def _curl_resolve_option(argv: list[str], index: int, result: dict[str, Any]) -> int:
    value, next_index = _option_value(argv, index)
    match = re.match(r"^(\[[^]]+\]|[^:]+):[^:]*:(.+)$", value or "")
    if not match:
        result["unclassified"].append(f"resolve:{value or ''}")
    else:
        _add_destination(result, match.group(1), "resolve-host")
        _add_destination(result, match.group(2), "resolve-address")
    return next_index


def _curl_connect_option(argv: list[str], index: int, result: dict[str, Any]) -> int:
    value, next_index = _option_value(argv, index)
    parts = (value or "").split(":")
    if len(parts) != 4:
        result["unclassified"].append(f"connect-to:{value or ''}")
        return next_index
    if parts[0]:
        _add_destination(result, parts[0], "connect-source")
    if parts[2]:
        _add_destination(result, parts[2], "connect-target")
    return next_index


def _curl_other_arg(
    argv: list[str],
    index: int,
    result: dict[str, Any],
    value_options: set[str],
    short_value_options: set[str],
) -> int:
    arg = argv[index]
    option = arg.split("=", 1)[0]
    if option in {"--config", "-K"} or arg.startswith("-K"):
        result["unclassified"].append("curl-config-file")
        return index + (2 if arg in {"--config", "-K"} else 1)
    if option in value_options:
        return _option_value(argv, index)[1]
    proxy_index = _curl_proxy_index(argv, index, result)
    if proxy_index is not None:
        return proxy_index
    if not arg.startswith("-"):
        _add_destination(result, arg, "url")
        return index + 1
    return _curl_short_value_index(argv, index, result, short_value_options) or index + 1


def _curl_proxy_index(
    argv: list[str], index: int, result: dict[str, Any]
) -> int | None:
    arg = argv[index]
    if arg != "-x" and not arg.startswith("-x"):
        return None
    value = argv[index + 1] if arg == "-x" and index + 1 < len(argv) else arg[2:]
    _add_destination(result, value, "proxy")
    return index + (2 if arg == "-x" else 1)


def _curl_short_value_index(
    argv: list[str],
    index: int,
    result: dict[str, Any],
    short_value_options: set[str],
) -> int | None:
    arg = argv[index]
    if arg in short_value_options:
        if index + 1 >= len(argv):
            result["unclassified"].append(f"missing:{arg}")
            return index + 1
        return index + 2
    if any(arg.startswith(item) and arg != item for item in short_value_options):
        return index + 1
    return None
