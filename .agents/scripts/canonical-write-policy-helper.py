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
from pathlib import Path
from typing import Any

from canonical_branch_policy import resolve_branch
from canonical_git_policy import _git_output as _shared_git_output
from canonical_git_policy import real_git


POLICY_VERSION = "canonical-write-policy-v1"


@dataclass
class Classification:
    """One repository-location classification."""

    classification: str
    inside_git: bool
    repo_root: str = ""
    git_dir: str = ""
    common_dir: str = ""
    branch: str = ""
    reason: str = ""


def _real_git() -> str:
    explicit = os.environ.get("AIDEVOPS_REAL_GIT_BIN", "") or os.environ.get(
        "AIDEVOPS_REAL_GIT", ""
    )
    if not explicit and os.path.isfile("/usr/bin/git"):
        explicit = "/usr/bin/git"
    return real_git(explicit)


def _git_output(cwd: Path, *args: str) -> str:
    try:
        return _shared_git_output(_real_git(), str(cwd), *args)
    except RuntimeError as exc:
        raise RuntimeError(f"Git repository probe failed: {exc}") from exc


def _existing_probe_path(raw_path: str) -> Path:
    path = Path(raw_path).expanduser().resolve(strict=False)
    if path.is_file() or path.is_symlink():
        path = path.parent
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def _repository_probes(probe_path: Path) -> dict[str, str]:
    return {
        "repo_root": _git_output(probe_path, "rev-parse", "--show-toplevel"),
        "git_dir": _git_output(probe_path, "rev-parse", "--git-dir"),
        "common_dir": _git_output(probe_path, "rev-parse", "--git-common-dir"),
        "branch": _git_output(probe_path, "branch", "--show-current"),
    }


def _absolute_probe_value(probe_path: Path, raw_value: str) -> str:
    path = Path(raw_value)
    if not path.is_absolute():
        path = probe_path / path
    return os.path.realpath(path)


def classify_location(raw_path: str) -> Classification:
    """Classify a path as canonical, linked, outside Git, or unknown."""
    probe_path = _existing_probe_path(raw_path)
    try:
        inside = _git_output(probe_path, "rev-parse", "--is-inside-work-tree")
    except RuntimeError as exc:
        return Classification("unknown", False, reason=str(exc))
    if inside != "true":
        return Classification(
            "outside", False, reason="path is outside a Git worktree"
        )

    try:
        values = _repository_probes(probe_path)
    except RuntimeError as exc:
        return Classification("unknown", True, reason=str(exc))

    required = ("repo_root", "git_dir", "common_dir")
    if any(not values[name] for name in required):
        return Classification(
            "unknown",
            True,
            reason="required Git worktree identity could not be resolved",
        )

    repo_root = _absolute_probe_value(probe_path, values["repo_root"])
    git_dir = _absolute_probe_value(probe_path, values["git_dir"])
    common_dir = _absolute_probe_value(probe_path, values["common_dir"])
    classification = "canonical" if git_dir == common_dir else "linked"
    return Classification(
        classification,
        True,
        repo_root=repo_root,
        git_dir=git_dir,
        common_dir=common_dir,
        branch=values["branch"],
        reason=(
            "Git directory equals common directory"
            if classification == "canonical"
            else "Git directory is isolated beneath the common directory"
        ),
    )


def _target_probe(cwd: str, file_path: str) -> str:
    if not file_path:
        return cwd
    target = Path(file_path).expanduser()
    if not target.is_absolute():
        target = Path(cwd) / target
    return str(target.resolve(strict=False))


def _is_target_led_linked_write(
    file_path: str, context: Classification, target: Classification
) -> bool:
    """Return whether a canonical context names a trusted linked target."""
    if not file_path or not Path(file_path).is_absolute():
        return False
    if context.classification != "canonical":
        return False
    if target.classification != "linked" or not context.common_dir:
        return False
    return context.common_dir == target.common_dir


def check_write(cwd: str, file_path: str) -> dict[str, Any]:
    """Return one fail-closed direct-file-write decision."""
    context = classify_location(cwd)
    target = classify_location(_target_probe(cwd, file_path))
    classifications = (context, target)
    unknown = next(
        (item for item in classifications if item.classification == "unknown"), None
    )
    canonical = next(
        (item for item in classifications if item.classification == "canonical"), None
    )
    target_led_linked_write = _is_target_led_linked_write(file_path, context, target)

    if unknown is not None:
        decision = "deny"
        reason = f"worktree classification failed closed: {unknown.reason}"
    elif canonical is not None and not target_led_linked_write:
        decision = "deny"
        reason = "canonical checkouts are read-only session mirrors"
    else:
        decision = "allow"
        reason = (
            "explicit absolute target is a linked worktree in the canonical repository"
            if target_led_linked_write
            else "write target and process context are outside canonical worktrees"
        )

    return {
        "policy": POLICY_VERSION,
        "decision": decision,
        "reason": reason,
        "action": (
            "create_or_use_linked_worktree" if decision == "deny" else "none"
        ),
        "context": asdict(context),
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
        context_decision = check_write(cwd, "")
        return {
            **context_decision,
            "decision": "deny",
            "reason": "apply-patch targets could not be classified safely",
            "action": "repair_or_use_linked_worktree",
            "patch_paths": [],
        }
    allowed_decision = check_write(cwd, paths[0])
    if allowed_decision["decision"] != "allow":
        return {**allowed_decision, "patch_paths": paths}
    for path in paths[1:]:
        decision = check_write(cwd, path)
        if decision["decision"] != "allow":
            return {**decision, "patch_paths": paths}
    return {**allowed_decision, "patch_paths": paths}


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
    if args.command == "check-write":
        _emit(check_write(args.cwd, args.path), args.field)
        return 0
    if args.command == "check-patch":
        _emit(check_patch(args.cwd, sys.stdin.read()), args.field)
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
