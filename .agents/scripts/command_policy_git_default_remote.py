#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Default git remote resolution for command-policy git analysis (GH#34040)."""

from __future__ import annotations

from command_policy_git_query import _run_git_query_detailed

_DEFAULT_REMOTE_CONFIG = r"^(remote\.pushdefault|branch\..*\.(remote|pushremote))$"
_HEADS_PREFIX = "refs/heads/"


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
        # An unreadable current branch must not deny the dispatched origin.
        # Classify the superset of remotes any branch could select; every
        # member still faces the tier policy.
        remotes = _every_default_remote(entries, subcommand)
        if remotes is None:
            return [], f"branch-query-{branch_failure}"
        return remotes, ""
    head_ref = branch_lines[0] if branch_lines else ""
    branch = head_ref[len(_HEADS_PREFIX):] if head_ref.startswith(_HEADS_PREFIX) else ""
    remote = _configured_default_remote(dict(entries), branch, subcommand)
    if remote.startswith("-"):
        return [], "option-like-remote"
    return [remote], ""


def _configured_default_remote(config: dict[str, str], branch: str, subcommand: str) -> str:
    keys = [f"branch.{branch}.remote"] if branch else []
    if subcommand == "push":
        branch_push = [f"branch.{branch}.pushremote"] if branch else []
        keys = branch_push + ["remote.pushdefault"] + keys
    return next((config[key] for key in keys if config.get(key)), "origin")


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
