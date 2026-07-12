#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git destination analysis for command-policy-helper.py."""

from __future__ import annotations

from typing import Any

from command_policy_http import _option_value
from command_policy_matchers import _git_parts
from command_policy_network import (
    _add_destination,
    _git_effective_cwd,
    _normalize_host,
    _resolve_git_remote,
)


def _analyze_git(argv: list[str], cwd: str, result: dict[str, Any]) -> bool:
    subcommand, args = _git_parts(argv)
    recognized = subcommand in {"clone", "fetch", "pull", "push", "ls-remote", "submodule"}
    if subcommand == "submodule":
        result["unclassified"].append("git-submodule-configured-remotes")
    elif recognized:
        _analyze_git_remote(argv, cwd, subcommand, args, result)
    return recognized


def _analyze_git_remote(
    argv: list[str], cwd: str, subcommand: str, args: list[str], result: dict[str, Any]
) -> None:
    _record_git_config_overrides(argv, result)
    value_options = {
        "-b", "--branch", "-o", "--origin", "-c", "--config", "--depth",
        "--reference", "--reference-if-able", "--separate-git-dir", "-j", "--jobs",
        "--filter", "--upload-pack", "--receive-pack", "--exec",
    }
    if subcommand == "clone":
        value_options.add("-u")
    candidate = _git_network_candidate(args, value_options)
    if not candidate:
        result["unclassified"].append(f"git-{subcommand}-destination-missing")
    elif not _classify_git_candidate(subcommand, candidate, result):
        remotes = _resolve_git_remote(_git_effective_cwd(argv, cwd), candidate)
        if remotes:
            for remote in remotes:
                _add_destination(result, remote, "git-remote")
        else:
            result["unclassified"].append(f"git-remote:{candidate}")


def _record_git_config_overrides(argv: list[str], result: dict[str, Any]) -> None:
    for index, arg in enumerate(argv[:-1]):
        if arg == "-c" and any(
            token in argv[index + 1].lower() for token in ("proxy", "insteadof")
        ):
            result["unclassified"].append("git-network-config-override")
        if arg == "--config-env":
            result["unclassified"].append("git-config-env-override")


def _git_network_candidate(args: list[str], value_options: set[str]) -> str:
    positionals: list[str] = []
    explicit_repo = ""
    index = 0
    while index < len(args):
        arg = args[index]
        option = arg.split("=", 1)[0]
        if option == "--repo":
            value, index = _option_value(args, index)
            explicit_repo = value or ""
            continue
        index = _record_git_argument(arg, option, index, value_options, positionals)
    return explicit_repo or (positionals[0] if positionals else "")


def _record_git_argument(
    arg: str,
    option: str,
    index: int,
    value_options: set[str],
    positionals: list[str],
) -> int:
    if option in value_options:
        return index + (1 if "=" in arg else 2)
    if not arg.startswith("-"):
        positionals.append(arg)
    return index + 1


def _classify_git_candidate(
    subcommand: str, candidate: str, result: dict[str, Any]
) -> bool:
    host = _normalize_host(candidate)
    if host:
        result["destinations"].append(host)
        return True
    if subcommand == "clone" and candidate.startswith(("/", "./", "../", "file://")):
        result["requires_destination"] = False
        return True
    return False
