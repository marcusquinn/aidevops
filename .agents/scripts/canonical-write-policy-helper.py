#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime-neutral canonical-versus-linked worktree policy.

The helper is intentionally process-based so shell, Claude Code, and OpenCode
all consume the same structural classification. Branch names never decide
whether a checkout is canonical: an absolute Git directory equal to the
absolute common directory is canonical, while a different Git directory is a
linked worktree.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import asdict, dataclass
from typing import Any

from canonical_branch_policy import resolve_branch
from canonical_write_policy_paths import (
    GIT_METADATA,
    GIT_WORKSPACE_ROOT_ENV,
    Classification,
    canonical_git_workspace_root as _canonical_git_workspace_root,
    classify_location,
    git_output as _git_output,
    git_symlink_origin as _git_symlink_origin,
    git_workspace_root_from_environment,
    is_within_workspace as _is_within_workspace,
    names_git_metadata as _names_git_metadata,
    repository_within_workspace as _repository_within_workspace,
    target_probe as _target_probe,
)
from canonical_write_runtime_allow import (
    canonical_runtime_write as _canonical_runtime_write,
    path_traverses_symlink as _path_traverses_symlink,
)
from canonical_write_worktree_base import worktree_base_dir_from_environment


POLICY_VERSION = "canonical-write-policy-v3"

CANONICAL_RUNTIME_ALLOW_REASON = (
    "canonical gitignored runtime path is allowlisted by the ignored "
    ".aidevops.json canonical_write_allow setting"
)


GIT_METADATA_ACTION = "use_git_commands_for_git_metadata"
GIT_METADATA_REASON = (
    "Git metadata (hooks, config, refs, gitfiles) is not writable through "
    "file tools; use Git commands or the aidevops hook installers"
)


SESSION_OUTSIDE_WORKSPACE_ACTION = "run_session_inside_git_workspace"
WORKSPACE_BOUNDARY_REASON = (
    "cross-repository linked worktree access is limited to the "
    "trusted Git workspace"
)
# GH#39739: the target worktree, not the session, is outside the boundary.
TARGET_OUTSIDE_WORKSPACE_ACTION = "include_worktree_in_git_workspace"


def _session_outside_reason(workspace_root: str) -> str:
    return (
        f"{WORKSPACE_BOUNDARY_REASON}: this session's project directory is "
        f"outside the trusted Git workspace ({workspace_root or 'unavailable'}); "
        "restart the session inside it, or set "
        f"{GIT_WORKSPACE_ROOT_ENV} to a directory that contains it"
    )


def _target_outside_reason(workspace_root: str, worktree_root: str) -> str:
    return (
        f"{WORKSPACE_BOUNDARY_REASON}: target worktree or its repository is "
        f"outside the trusted Git workspace ({workspace_root or 'unavailable'}) "
        f"and the trusted worktree base ({worktree_root or 'unavailable'}); "
        f"set {GIT_WORKSPACE_ROOT_ENV} to a directory that contains the "
        "worktree and its repository, or create the worktree with "
        "worktree-helper.sh under the configured worktree base"
    )


def _write_action(
    decision: str,
    cross_repository_target: bool,
    symlink_workspace_escape: bool,
    session_outside_workspace: bool = False,
) -> str:
    if decision != "deny":
        return "none"
    # First matching rule wins. When the session location is the problem, the
    # worktree already exists, so the remedy is to relocate the session.
    candidates = (
        (symlink_workspace_escape, "use_direct_sanctioned_outside_path"),
        (
            cross_repository_target and session_outside_workspace,
            SESSION_OUTSIDE_WORKSPACE_ACTION,
        ),
        (cross_repository_target, TARGET_OUTSIDE_WORKSPACE_ACTION),
    )
    return next(
        (action for matched, action in candidates if matched),
        "create_or_use_linked_worktree",
    )


def _canonical_write_decision(
    target: Classification, target_probe: str, cwd: str, file_path: str
) -> tuple[str, str, str]:
    """GH#39573: only opted-in, ignored, untracked runtime output is writable.

    Every other canonical target keeps the read-only deny. Any symlink in the
    unresolved path, including an alias above the checkout, voids the
    exemption.
    """
    allowed, runtime_allow = _canonical_runtime_write(
        target, target_probe, _path_traverses_symlink(cwd, file_path)
    )
    if allowed:
        return "allow", CANONICAL_RUNTIME_ALLOW_REASON, runtime_allow
    return (
        "deny",
        "canonical checkouts are read-only session mirrors",
        runtime_allow,
    )


@dataclass
class _WriteFacts:
    """Structural facts about one direct-file-write request."""

    context: Classification
    target: Classification
    target_probe: str
    workspace_root: str
    worktree_root: str
    cross_repository_target: bool
    symlink_workspace_escape: bool
    context_within_workspace: bool
    target_within_workspace: bool
    git_metadata_target: bool


def _trusted_worktree_root() -> str:
    """Return the configured worktree base unless it contains the home directory."""
    root = _canonical_git_workspace_root(worktree_base_dir_from_environment())
    home = os.path.realpath(os.path.expanduser("~"))
    if root and _is_within_workspace(home, root):
        return ""
    return root


def _trusted_roots() -> tuple[str, str]:
    """Return the canonical Git workspace root and trusted worktree base."""
    return (
        _canonical_git_workspace_root(git_workspace_root_from_environment()),
        _trusted_worktree_root(),
    )


def _context_within_workspace(
    context: Classification, cwd: str, workspace_root: str, worktree_root: str
) -> bool:
    if context.inside_git:
        return _repository_within_workspace(context, workspace_root, worktree_root)
    return _is_within_workspace(cwd, workspace_root)


def _write_target(cwd: str, file_path: str) -> tuple[Classification, str, Any]:
    if not file_path:
        empty = Classification("unknown", False, reason="write target is empty")
        return empty, cwd, None
    target_probe = _target_probe(cwd, file_path)
    return (
        classify_location(target_probe),
        target_probe,
        _git_symlink_origin(cwd, file_path),
    )


def _write_facts(cwd: str, file_path: str) -> _WriteFacts:
    context = classify_location(cwd)
    target, target_probe, symlink_origin = _write_target(cwd, file_path)
    workspace_root, worktree_root = _trusted_roots()
    return _WriteFacts(
        context=context,
        target=target,
        target_probe=target_probe,
        workspace_root=workspace_root,
        worktree_root=worktree_root,
        cross_repository_target=target.classification == "linked" and (
            not context.inside_git or target.common_dir != context.common_dir
        ),
        symlink_workspace_escape=(
            symlink_origin is not None
            and target.classification == "outside"
            and not _is_within_workspace(target_probe, workspace_root)
        ),
        context_within_workspace=_context_within_workspace(
            context, cwd, workspace_root, worktree_root
        ),
        target_within_workspace=_repository_within_workspace(
            target, workspace_root, worktree_root
        ),
        git_metadata_target=target.classification == GIT_METADATA or (
            target.inside_git
            and _names_git_metadata(target.repo_root, target_probe)
        ),
    )


def _allow_reason(facts: _WriteFacts) -> str:
    if facts.cross_repository_target:
        return (
            "cross-repository write target resolves inside a linked worktree "
            "within the trusted Git workspace"
        )
    if facts.target.classification == "linked":
        return "write target resolves inside an allowed linked worktree"
    return "write target is outside canonical worktrees"


def _non_canonical_decision(facts: _WriteFacts) -> tuple[str, str]:
    # First matching deny wins. GH#39582: hooks, config and refs change only
    # through Git commands or the sanctioned hook installers.
    denies = (
        (facts.git_metadata_target, GIT_METADATA_REASON),
        (
            facts.symlink_workspace_escape,
            "symlinked write target escapes from a Git worktree outside the "
            "trusted Git workspace",
        ),
        (
            facts.cross_repository_target and not facts.context_within_workspace,
            _session_outside_reason(facts.workspace_root),
        ),
        (
            facts.cross_repository_target and not facts.target_within_workspace,
            _target_outside_reason(facts.workspace_root, facts.worktree_root),
        ),
    )
    deny_reason = next((reason for matched, reason in denies if matched), None)
    if deny_reason is None:
        return "allow", _allow_reason(facts)
    return "deny", deny_reason


def check_write(cwd: str, file_path: str) -> dict[str, Any]:
    """Return one fail-closed direct-file-write decision."""
    facts = _write_facts(cwd, file_path)
    target = facts.target
    runtime_allow = "not-applicable"
    if target.classification == "unknown":
        decision = "deny"
        reason = f"write target classification failed closed: {target.reason}"
    elif target.classification == "canonical":
        decision, reason, runtime_allow = _canonical_write_decision(
            target, facts.target_probe, cwd, file_path
        )
    else:
        decision, reason = _non_canonical_decision(facts)

    return {
        "policy": POLICY_VERSION,
        "git_workspace_root": facts.workspace_root,
        "trusted_worktree_root": facts.worktree_root,
        "decision": decision,
        "reason": reason,
        "action": (
            GIT_METADATA_ACTION
            if decision == "deny" and facts.git_metadata_target
            else _write_action(
                decision,
                facts.cross_repository_target,
                facts.symlink_workspace_escape,
                not facts.context_within_workspace,
            )
        ),
        "canonical_runtime_allow": runtime_allow,
        "context": asdict(facts.context),
        "target": asdict(target),
    }


def check_session(cwd: str, target_path: str) -> dict[str, Any]:
    """Deny early when the session location cannot edit a cross-repo target.

    Mirrors the direct-write boundary in check_write without needing the
    target worktree to exist yet; a non-Git target is not subject to it.
    """
    context = classify_location(cwd)
    target = classify_location(target_path)
    workspace_root, worktree_root = _trusted_roots()
    cross_repository_target = target.inside_git and (
        not context.inside_git or target.common_dir != context.common_dir
    )
    denied = cross_repository_target and not _context_within_workspace(
        context, cwd, workspace_root, worktree_root
    )
    return {
        "policy": POLICY_VERSION,
        "git_workspace_root": workspace_root,
        "trusted_worktree_root": worktree_root,
        "decision": "deny" if denied else "allow",
        "reason": (
            _session_outside_reason(workspace_root)
            if denied
            else "session location permits the target"
        ),
        "action": SESSION_OUTSIDE_WORKSPACE_ACTION if denied else "none",
        "context": asdict(context),
        "target": asdict(target),
    }


def check_worktree(worktree_path: str) -> dict[str, Any]:
    """Report whether other repositories' sessions may write a linked worktree.

    GH#39739: worktree-helper.sh warns at creation instead of the first edit.
    """
    target = classify_location(worktree_path)
    workspace_root, worktree_root = _trusted_roots()
    linked = target.classification == "linked"
    trusted = linked and _repository_within_workspace(
        target, workspace_root, worktree_root
    )
    if trusted:
        reason = (
            "linked worktree is writable from sessions in other trusted "
            "repositories"
        )
    elif linked:
        reason = _target_outside_reason(workspace_root, worktree_root)
    else:
        reason = f"path is not a linked worktree ({target.classification})"
    return {
        "policy": POLICY_VERSION,
        "git_workspace_root": workspace_root,
        "trusted_worktree_root": worktree_root,
        "decision": "trusted" if trusted else "untrusted",
        "reason": reason,
        "target": asdict(target),
    }


def _patch_paths(patch_text: str) -> list[str]:
    paths: list[str] = []
    header_pattern = re.compile(
        r"^\*\*\* (?:Add|Update|Delete) File: (?P<path>.+)$"
    )
    move_pattern = re.compile(r"^\*\*\* Move to: (?P<path>.+)$")
    for line in patch_text.splitlines():
        match = header_pattern.match(line) or move_pattern.match(line)
        if match:
            paths.append(match.group("path"))
    return paths


def check_patch(cwd: str, patch_text: str) -> dict[str, Any]:
    """Return one fail-closed decision for every target in an apply patch."""
    paths = _patch_paths(patch_text)
    if not paths:
        empty_decision = check_write(cwd, "")
        return {
            **empty_decision,
            "decision": "deny",
            "reason": "apply-patch targets could not be classified safely",
            "action": "repair_or_use_linked_worktree",
            "patch_paths": [],
        }
    for path in paths:
        decision = check_write(cwd, path)
        if decision["decision"] != "allow":
            return {**decision, "patch_paths": paths}
    return {**decision, "patch_paths": paths}


def resolve_canonical_branch(cwd: str) -> dict[str, str]:
    classification = classify_location(cwd)
    if classification.classification not in {"canonical", "linked"}:
        raise RuntimeError(
            "canonical branch requires a classified Git worktree: "
            f"{classification.reason}"
        )
    return resolve_branch(classification.repo_root, _git_output, POLICY_VERSION)


def _emit(payload: dict[str, Any], field: str) -> None:
    if field:
        value = payload.get(field, "")
        if isinstance(value, (dict, list)):
            print(json.dumps(value, sort_keys=True))
        else:
            print(value)
        return
    print(json.dumps(payload, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify_parser = subparsers.add_parser("classify")
    classify_parser.add_argument("--cwd", default=os.getcwd())
    classify_parser.add_argument("--field", default="")

    write_parser = subparsers.add_parser("check-write")
    write_parser.add_argument("--cwd", default=os.getcwd())
    write_parser.add_argument("--path", default="")
    write_parser.add_argument("--field", default="")

    session_parser = subparsers.add_parser("check-session")
    session_parser.add_argument("--cwd", default=os.getcwd())
    session_parser.add_argument("--target", required=True)
    session_parser.add_argument("--field", default="")

    worktree_parser = subparsers.add_parser("check-worktree")
    worktree_parser.add_argument("--path", required=True)
    worktree_parser.add_argument("--field", default="")

    patch_parser = subparsers.add_parser("check-patch")
    patch_parser.add_argument("--cwd", default=os.getcwd())
    patch_parser.add_argument("--field", default="")

    branch_parser = subparsers.add_parser("resolve-branch")
    branch_parser.add_argument("--cwd", default=os.getcwd())
    branch_parser.add_argument("--field", default="")

    args = parser.parse_args()
    if args.command == "classify":
        result = classify_location(args.cwd)
        payload = {"policy": POLICY_VERSION, **asdict(result)}
        _emit(payload, args.field)
        return 2 if result.classification == "unknown" else 0
    decisions = {
        "check-write": lambda: check_write(args.cwd, args.path),
        "check-session": lambda: check_session(args.cwd, args.target),
        "check-worktree": lambda: check_worktree(args.path),
        "check-patch": lambda: check_patch(args.cwd, sys.stdin.read()),
    }
    if args.command in decisions:
        _emit(decisions[args.command](), args.field)
        return 0
    try:
        payload = resolve_canonical_branch(args.cwd)
    except RuntimeError as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    _emit(payload, args.field)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
