#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""SSH and SCP destination analysis for command-policy-helper.py."""

from __future__ import annotations

from typing import Any

from command_policy_network import _add_destination, _normalize_host


def _analyze_ssh(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {
        "-b",
        "-c",
        "-D",
        "-E",
        "-e",
        "-F",
        "-I",
        "-i",
        "-L",
        "-l",
        "-m",
        "-O",
        "-o",
        "-p",
        "-Q",
        "-R",
        "-S",
        "-W",
        "-w",
        "-J",
    }
    index = 1
    target = ""
    while index < len(argv):
        index, target, complete = _ssh_arg(argv, index, result, value_options)
        if target or not complete:
            break
    if target:
        _add_destination(result, target, "ssh-target")
    else:
        result["unclassified"].append("ssh-target-missing")


def _ssh_arg(
    argv: list[str], index: int, result: dict[str, Any], value_options: set[str]
) -> tuple[int, str, bool]:
    arg = argv[index]
    target = ""
    complete = True
    if arg.startswith("-J") and arg != "-J":
        _add_destination(result, arg[2:], "proxy-jump")
        index += 1
    elif arg in value_options:
        index, complete = _ssh_value_option(argv, index, result)
    elif arg.startswith("-"):
        index += 1
    else:
        target = arg
    return index, target, complete


def _ssh_value_option(
    argv: list[str], index: int, result: dict[str, Any]
) -> tuple[int, bool]:
    arg = argv[index]
    if index + 1 >= len(argv):
        result["unclassified"].append(f"missing:{arg}")
        return index, False
    value = argv[index + 1]
    if arg == "-J":
        for jump in value.split(","):
            _add_destination(result, jump, "proxy-jump")
    elif arg == "-F":
        result["unclassified"].append("ssh-config-file")
    elif arg == "-W":
        _add_destination(result, value.rsplit(":", 1)[0], "stdio-forward")
    elif arg in {"-L", "-R"}:
        _ssh_forward_destination(value, result)
    elif arg == "-o":
        _ssh_extended_option(value, result)
    return index + 2, True


def _ssh_forward_destination(value: str, result: dict[str, Any]) -> None:
    parts = value.split(":")
    if len(parts) >= 3:
        _add_destination(result, parts[-2], "port-forward")
    else:
        result["unclassified"].append(f"ssh-forward:{value}")


def _ssh_extended_option(value: str, result: dict[str, Any]) -> None:
    lower = value.lower()
    if lower.startswith("proxyjump="):
        _add_destination(result, value.split("=", 1)[1], "proxy-jump")
    elif lower.startswith("proxycommand="):
        result["unclassified"].append("ssh-proxy-command")


def _analyze_scp(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {"-c", "-F", "-i", "-J", "-l", "-o", "-P", "-S", "-X"}
    index = 1
    remote_count = 0
    while index < len(argv):
        index, remote, complete = _scp_arg(argv, index, result, value_options)
        remote_count += int(remote)
        if not complete:
            break
    if remote_count == 0:
        result["unclassified"].append("scp-remote-missing")


def _scp_arg(
    argv: list[str], index: int, result: dict[str, Any], value_options: set[str]
) -> tuple[int, bool, bool]:
    arg = argv[index]
    remote = False
    complete = True
    if arg in value_options:
        if index + 1 >= len(argv):
            result["unclassified"].append(f"missing:{arg}")
            complete = False
        else:
            _classify_scp_option(arg, argv[index + 1], result)
            index += 2
    elif arg.startswith("-"):
        index += 1
    else:
        remote = bool(_normalize_host(arg))
        if remote:
            _add_destination(result, arg, "scp-remote")
        index += 1
    return index, remote, complete


def _classify_scp_option(arg: str, value: str, result: dict[str, Any]) -> None:
    if arg == "-J":
        _add_destination(result, value, "proxy-jump")
    elif arg in {"-F", "-S"}:
        result["unclassified"].append(f"scp-hidden-network-config:{arg}")
    elif arg == "-o" and value.lower().startswith("proxycommand="):
        result["unclassified"].append("scp-proxy-command")
