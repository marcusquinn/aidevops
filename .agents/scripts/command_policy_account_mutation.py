#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Trusted authorization for protected GitHub account mutations."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from command_policy_config import _decision
from command_policy_matchers import _matches_gh_command_path

WORKSPACE_ROOT_ENV = "AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT"


@dataclass(frozen=True)
class _RemoteOptionPolicy:
    boolean_options: frozenset[str]
    value_options: frozenset[str]
    exact_options: frozenset[str] = frozenset()
    explicit_remote_value_options: frozenset[str] = frozenset()


@dataclass(frozen=True)
class _AccountMutationContext:
    authorization: str
    source: dict[str, Any] | None
    workspace_root: str | None


_FORK_OPTIONS = _RemoteOptionPolicy(
    boolean_options=frozenset({"--default-branch-only"}),
    value_options=frozenset({"--fork-name", "--org"}),
    exact_options=frozenset({"--clone=false"}),
)
_CREATE_OPTIONS = _RemoteOptionPolicy(
    boolean_options=frozenset(
        {
            "--add-readme",
            "--disable-issues",
            "--disable-wiki",
            "--include-all-branches",
            "--internal",
            "--private",
            "--public",
        }
    ),
    value_options=frozenset(
        {
            "--description",
            "--gitignore",
            "--homepage",
            "--license",
            "--team",
            "--template",
            "-d",
            "-g",
            "-h",
            "-l",
            "-p",
            "-t",
        }
    ),
    explicit_remote_value_options=frozenset({"--template", "-p"}),
)
_CREATE_VISIBILITY = frozenset({"--internal", "--private", "--public"})


def account_mutation_workspace_root_from_environment() -> str:
    """Return the inherited workspace root, defaulting to the projects directory."""
    if WORKSPACE_ROOT_ENV in os.environ:
        return os.environ[WORKSPACE_ROOT_ENV]
    return str(Path.home() / "Git")


def _account_mutation_guard(policy: dict[str, Any]) -> dict[str, Any]:
    return next(
        guard
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "trusted_account_mutation"
    )


def _is_protected_account_mutation(
    argv: list[str], command_paths: list[list[str]]
) -> bool:
    help_only = len(argv) == 4 and argv[3] == "--help"
    return _matches_gh_command_path(argv, command_paths) and not help_only


def _is_explicit_remote(repository: str) -> bool:
    return re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9_.-]+",
        repository,
    ) is not None


def _consume_remote_only_options(
    args: list[str], policy: _RemoteOptionPolicy
) -> set[str] | None:
    seen: set[str] = set()
    index = 0
    while index < len(args):
        consumed = _consume_remote_only_option(args, index, policy)
        if consumed is None:
            return None
        option, index = consumed
        seen.add(option)
    return seen


def _consume_remote_only_option(
    args: list[str], index: int, policy: _RemoteOptionPolicy
) -> tuple[str, int] | None:
    option = args[index]
    if option in policy.exact_options or option in policy.boolean_options:
        return option, index + 1
    if "=" in option:
        normalized = _normalize_attached_option(option, policy)
        return (normalized, index + 1) if normalized else None
    if option not in policy.value_options or index + 1 >= len(args):
        return None
    if not _is_remote_only_option_value(option, args[index + 1], policy):
        return None
    return option, index + 2


def _normalize_attached_option(
    option: str, policy: _RemoteOptionPolicy
) -> str | None:
    name, _, value = option.partition("=")
    if name in policy.boolean_options:
        return name if value == "true" else None
    if name in policy.value_options and _is_remote_only_option_value(
        name, value, policy
    ):
        return name
    return None


def _is_remote_only_option_value(
    option: str, value: str, policy: _RemoteOptionPolicy
) -> bool:
    if not value:
        return False
    return (
        option not in policy.explicit_remote_value_options
        or _is_explicit_remote(value)
    )


def _is_workspace_safe_fork(argv: list[str]) -> bool:
    if len(argv) < 5 or not _is_explicit_remote(argv[3]):
        return False
    seen = _consume_remote_only_options(argv[4:], _FORK_OPTIONS)
    return seen is not None and "--clone=false" in seen


def _is_workspace_safe_create(argv: list[str]) -> bool:
    if len(argv) < 5 or argv[3].startswith("-") or argv[3] in {".", ".."}:
        return False
    seen = _consume_remote_only_options(argv[4:], _CREATE_OPTIONS)
    return seen is not None and bool(seen & _CREATE_VISIBILITY)


def _is_workspace_safe_account_mutation(argv: list[str]) -> bool:
    if len(argv) < 3 or argv[1] != "repo":
        return False
    if argv[2] == "fork":
        return _is_workspace_safe_fork(argv)
    if argv[2] in {"create", "new"}:
        return _is_workspace_safe_create(argv)
    return False


def _canonical_workspace_root(workspace_root: str) -> str:
    if not workspace_root:
        return ""
    root = os.path.realpath(os.path.expanduser(workspace_root))
    home = os.path.realpath(str(Path.home()))
    if root in {os.path.abspath(os.sep), home} or not os.path.isdir(root):
        return ""
    return root


def _is_within_workspace(cwd: str, workspace_root: str) -> bool:
    if not os.path.isdir(cwd):
        return False
    try:
        return os.path.commonpath([cwd, workspace_root]) == workspace_root
    except ValueError:
        return False


def _account_mutation_location(
    argv: list[str], cwd: str, workspace_root: str
) -> dict[str, str]:
    canonical_cwd = os.path.realpath(cwd)
    canonical_root = _canonical_workspace_root(workspace_root)
    if (
        canonical_root
        and _is_workspace_safe_account_mutation(argv)
        and _is_within_workspace(canonical_cwd, canonical_root)
    ):
        return {"kind": "workspace", "path": canonical_root}
    return {"kind": "cwd", "path": canonical_cwd}


def _authorization_digest(payload: dict[str, Any]) -> str:
    canonical = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(canonical).hexdigest()}"


def account_mutation_authorization(
    argv: list[str],
    cwd: str,
    source: dict[str, Any] | None = None,
    workspace_root: str | None = None,
) -> str:
    if workspace_root is None:
        workspace_root = account_mutation_workspace_root_from_environment()
    return _authorization_digest(
        {
            "argv": argv,
            "location": _account_mutation_location(argv, cwd, workspace_root),
            "schema": "aidevops-command-authorization/v2",
            "source": source or {"kind": "invocations", "value": [argv]},
        }
    )


def _legacy_account_mutation_authorization(
    argv: list[str], cwd: str, source: dict[str, Any] | None = None
) -> str:
    return _authorization_digest(
        {
            "argv": argv,
            "cwd": os.path.realpath(cwd),
            "schema": "aidevops-command-authorization/v1",
            "source": source or {"kind": "invocations", "value": [argv]},
        }
    )


def _authorization_matches(
    context: _AccountMutationContext,
    argv: list[str],
    cwd: str,
) -> bool:
    if not context.authorization:
        return False
    current = account_mutation_authorization(
        argv, cwd, context.source, context.workspace_root
    )
    legacy = _legacy_account_mutation_authorization(argv, cwd, context.source)
    return secrets.compare_digest(
        context.authorization, current
    ) or secrets.compare_digest(
        context.authorization, legacy
    )


def _evaluate_account_mutation(
    invocations: list[list[str]],
    cwd: str,
    policy: dict[str, Any],
    context: _AccountMutationContext,
) -> dict[str, Any]:
    guard = _account_mutation_guard(policy)
    mutations = [
        argv
        for argv in invocations
        if _is_protected_account_mutation(argv, guard["command_paths"])
    ]
    if not mutations:
        return _decision(
            "allow",
            "github.no-account-mutation",
            "No protected GitHub account mutation detected",
        )
    if len(invocations) != 1 or len(mutations) != 1:
        return _decision(
            "forbid",
            guard["id"],
            "Protected GitHub account mutations must be authorized as one exact command",
        )
    # #aidevops:trust-boundary — only inherited authorization and workspace
    # context can cross this gate; command-local assignments are rejected.
    if _authorization_matches(context, mutations[0], cwd):
        return _decision(
            "allow",
            "github.account-mutation-authorized",
            "Exact GitHub account mutation matches trusted authorization",
        )
    return _decision(
        "forbid",
        guard["id"],
        "GitHub account mutation requires exact trusted authorization",
    )
