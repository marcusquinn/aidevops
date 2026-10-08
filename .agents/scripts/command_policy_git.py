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
    _run_git_query_detailed,
)

_DEFAULT_REMOTE_CONFIG = r"^(remote\.pushdefault|branch\..*\.(remote|pushremote))$"


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
    git_cwd = _git_effective_cwd(argv, cwd)
    candidates = _git_network_candidates(subcommand, args, value_options)
    if candidates is None:
        result["unclassified"].append(f"git-{subcommand}-all-remotes")
        return
    failure = ""
    if not candidates and subcommand != "clone":
        candidates, failure = _default_git_remote(git_cwd, subcommand)
    if not candidates:
        # GH#34040: name the failed resolution step so a denial is attributable.
        detail = f"({failure})" if failure else ""
        result["unclassified"].append(f"git-{subcommand}-destination-missing{detail}")
    for candidate in candidates:
        _classify_git_destination(git_cwd, subcommand, candidate, result)


def _classify_git_destination(
    cwd: str, subcommand: str, candidate: str, result: dict[str, Any]
) -> None:
    if _classify_git_candidate(subcommand, candidate, result):
        return
    remotes = _resolve_git_remote(cwd, candidate, include_push=subcommand == "push")
    if not remotes:
        result["unclassified"].append(f"git-remote:{candidate}")
    for remote in remotes:
        _add_destination(result, remote, "git-remote")


def _default_git_remote(cwd: str, subcommand: str) -> tuple[list[str], str]:
    """Return the remote git itself contacts when none is named.

    Push: branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote, origin.
    Fetch, pull and ls-remote: branch.<b>.remote, origin.
    Returns (remotes, failure); remotes is [] with a fixed failure token when
    the default remote cannot be bounded.
    """
    config_lines, config_failure = _run_git_query_detailed(
        cwd, ["config", "--get-regexp", _DEFAULT_REMOTE_CONFIG], ok_codes=(0, 1)
    )
    if config_lines is None:
        return [], f"config-query-{config_failure}"
    entries = [
        (key, value.strip())
        for key, _, value in (line.partition(" ") for line in config_lines)
    ]
    # Plumbing, not porcelain `git branch --show-current`; exit 1 = detached.
    branch_lines, branch_failure = _run_git_query_detailed(
        cwd, ["symbolic-ref", "--quiet", "HEAD"], ok_codes=(0, 1)
    )
    if branch_lines is None:
        # GH#34040: an unreadable current branch must not deny the dispatched
        # origin. Classify the superset of remotes any branch could select;
        # every member still faces the tier policy.
        remotes = _every_default_remote(entries, subcommand)
        if remotes is None:
            return [], f"branch-query-{branch_failure}"
        return remotes, ""
    config = dict(entries)
    head_ref = branch_lines[0] if branch_lines else ""
    heads_prefix = "refs/heads/"
    branch = head_ref[len(heads_prefix):] if head_ref.startswith(heads_prefix) else ""
    keys = [f"branch.{branch}.remote"] if branch else []
    if subcommand == "push":
        branch_push = [f"branch.{branch}.pushremote"] if branch else []
        keys = branch_push + ["remote.pushdefault"] + keys
    remote = next((config[key] for key in keys if config.get(key)), "origin")
    if remote.startswith("-"):
        return [], "option-like-remote"
    return [remote], ""


def _every_default_remote(
    entries: list[tuple[str, str]], subcommand: str
) -> list[str] | None:
    """Return every remote a default lookup could select; None if unsafe.

    A "." remote is the local repository and has no network destination.
    """
    remotes = ["origin"]
    for key, value in entries:
        if not value or value == ".":
            continue
        if subcommand != "push" and (
            key == "remote.pushdefault" or key.endswith(".pushremote")
        ):
            continue
        if value.startswith("-"):
            return None
        if value not in remotes:
            remotes.append(value)
    return remotes


def _record_git_config_overrides(argv: list[str], result: dict[str, Any]) -> None:
    """Fail closed on options that change which remote or URL git contacts."""
    for index, arg in enumerate(argv):
        value = argv[index + 1] if index + 1 < len(argv) else ""
        if arg in {"-c", "--config"} and _is_network_config(value):
            result["unclassified"].append("git-network-config-override")
        if arg.startswith("--config=") and _is_network_config(arg.split("=", 1)[1]):
            result["unclassified"].append("git-network-config-override")
        if arg == "--config-env" or arg.startswith("--config-env="):
            result["unclassified"].append("git-config-env-override")
        if arg == "--git-dir" or arg.startswith("--git-dir="):
            result["unclassified"].append("git-repository-override")


def _is_network_config(assignment: str) -> bool:
    lowered = assignment.lower()
    key = lowered.split("=", 1)[0]
    return (
        key.startswith(("remote.", "branch.", "url."))
        or key == "core.sshcommand"
        or any(token in lowered for token in ("proxy", "insteadof"))
    )


def _git_network_candidates(
    subcommand: str, args: list[str], value_options: set[str]
) -> list[str] | None:
    """Return named remotes or URLs; None means every configured remote."""
    positionals: list[str] = []
    flags: set[str] = set()
    explicit_repo = ""
    index = 0
    while index < len(args):
        arg = args[index]
        option = arg.split("=", 1)[0]
        if option == "--repo":
            value, index = _option_value(args, index)
            explicit_repo = value or ""
            continue
        if arg.startswith("-") and option not in value_options:
            flags.add(option)
        index = _record_git_argument(arg, option, index, value_options, positionals)
    if explicit_repo:
        return [explicit_repo]
    if subcommand in {"fetch", "pull"} and "--all" in flags:
        return None
    return positionals if "--multiple" in flags else positionals[:1]


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
