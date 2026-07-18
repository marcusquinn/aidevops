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
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


POLICY_VERSION = "canonical-write-policy-v1"
BRANCH_CONFIG_KEYS = (
    "canonical_branch",
    "integration_branch",
    "dispatch_base_branch",
    "pr_base_branch",
    "pr_target_branch",
    "base_branch",
    "default_branch",
)


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
    if explicit:
        return explicit
    if os.path.isfile("/usr/bin/git"):
        return "/usr/bin/git"
    return shutil.which("git") or "git"


def _run_git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [_real_git(), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"Git repository probe failed: {exc}") from exc


def _existing_probe_path(raw_path: str) -> Path:
    path = Path(raw_path).expanduser().resolve(strict=False)
    if path.is_file() or path.is_symlink():
        path = path.parent
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def classify_location(raw_path: str) -> Classification:
    """Classify a path as canonical, linked, outside Git, or unknown."""
    probe_path = _existing_probe_path(raw_path)
    try:
        inside_result = _run_git(probe_path, "rev-parse", "--is-inside-work-tree")
    except RuntimeError as exc:
        return Classification("unknown", False, reason=str(exc))
    if inside_result.returncode != 0 or inside_result.stdout.strip() != "true":
        return Classification(
            "outside", False, reason="path is outside a Git worktree"
        )

    try:
        probes = {
            "repo_root": _run_git(
                probe_path, "rev-parse", "--path-format=absolute", "--show-toplevel"
            ),
            "git_dir": _run_git(
                probe_path, "rev-parse", "--path-format=absolute", "--git-dir"
            ),
            "common_dir": _run_git(
                probe_path,
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ),
            "branch": _run_git(probe_path, "branch", "--show-current"),
        }
    except RuntimeError as exc:
        return Classification("unknown", True, reason=str(exc))

    required = ("repo_root", "git_dir", "common_dir")
    if any(probes[name].returncode != 0 or not probes[name].stdout.strip() for name in required):
        return Classification(
            "unknown",
            True,
            reason="required Git worktree identity could not be resolved",
        )

    values = {name: result.stdout.strip() for name, result in probes.items()}
    git_dir = os.path.realpath(values["git_dir"])
    common_dir = os.path.realpath(values["common_dir"])
    classification = "canonical" if git_dir == common_dir else "linked"
    return Classification(
        classification,
        True,
        repo_root=os.path.realpath(values["repo_root"]),
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

    if unknown is not None:
        decision = "deny"
        reason = f"worktree classification failed closed: {unknown.reason}"
    elif canonical is not None:
        decision = "deny"
        reason = "canonical checkouts are read-only session mirrors"
    else:
        decision = "allow"
        reason = "write target and process context are outside canonical worktrees"

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
    context_decision = check_write(cwd, "")
    if context_decision["decision"] != "allow":
        return context_decision
    paths = _patch_paths(patch_text)
    if not paths:
        return {
            **context_decision,
            "decision": "deny",
            "reason": "apply-patch targets could not be classified safely",
            "action": "repair_or_use_linked_worktree",
            "patch_paths": [],
        }
    for path in paths:
        decision = check_write(cwd, path)
        if decision["decision"] != "allow":
            return {**decision, "patch_paths": paths}
    return {**context_decision, "patch_paths": paths}


def _normalise_branch(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    branch = value.strip()
    for prefix in ("refs/heads/", "refs/remotes/origin/", "origin/"):
        if branch.startswith(prefix):
            branch = branch[len(prefix) :]
            break
    return branch


def _branch_from_mapping(mapping: Any) -> str:
    if not isinstance(mapping, dict):
        return ""
    for key in BRANCH_CONFIG_KEYS:
        branch = _normalise_branch(mapping.get(key))
        if branch:
            return branch
    return ""


def _load_json_text(payload: str, source: str) -> Any:
    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"configured branch metadata is unreadable: {source}: {exc}"
        ) from exc


def _load_json(path: Path) -> Any:
    try:
        return _load_json_text(path.read_text(encoding="utf-8"), str(path))
    except OSError as exc:
        raise RuntimeError(
            f"configured branch metadata is unreadable: {path}: {exc}"
        ) from exc


def _origin_slug(repo_root: str) -> str:
    result = _run_git(Path(repo_root), "remote", "get-url", "origin")
    if result.returncode != 0:
        return ""
    remote = result.stdout.strip()
    match = re.search(r"github\.com[/:]([^/\s]+/[^/\s]+?)(?:\.git)?$", remote)
    return match.group(1) if match else ""


def _project_branch(repo_root: str) -> tuple[str, str]:
    result = _run_git(Path(repo_root), "show", "HEAD:.aidevops.json")
    if result.returncode != 0:
        return "", ""
    branch = _branch_from_mapping(
        _load_json_text(result.stdout, "HEAD:.aidevops.json")
    )
    return (branch, "project-config-at-head") if branch else ("", "")


def _registered_branch(repo_root: str) -> tuple[str, str]:
    configured_path = os.environ.get("AIDEVOPS_REPOS_CONFIG", "")
    config_path = (
        Path(configured_path).expanduser()
        if configured_path
        else Path.home() / ".config" / "aidevops" / "repos.json"
    )
    if not config_path.is_file():
        return "", ""
    payload = _load_json(config_path)
    entries = payload.get("initialized_repos", []) if isinstance(payload, dict) else []
    slug = _origin_slug(repo_root)
    canonical_root = os.path.realpath(repo_root)
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        entry_slug = entry.get("slug", "")
        entry_path = entry.get("path", "") or entry.get("repo_path", "")
        path_matches = bool(entry_path) and os.path.realpath(
            os.path.expanduser(str(entry_path))
        ) == canonical_root
        if (slug and entry_slug == slug) or path_matches:
            branch = _branch_from_mapping(entry)
            if branch:
                return branch, "registered-repo-config"
    return "", ""


def _origin_default_branch(repo_root: str) -> tuple[str, str]:
    result = _run_git(
        Path(repo_root),
        "symbolic-ref",
        "--quiet",
        "--short",
        "refs/remotes/origin/HEAD",
    )
    if result.returncode != 0:
        return "", ""
    branch = _normalise_branch(result.stdout)
    return (branch, "origin-head") if branch else ("", "")


def _valid_branch(repo_root: str, branch: str) -> bool:
    result = _run_git(Path(repo_root), "check-ref-format", "--branch", branch)
    return result.returncode == 0


def resolve_canonical_branch(cwd: str) -> dict[str, str]:
    classification = classify_location(cwd)
    if classification.classification not in {"canonical", "linked"}:
        raise RuntimeError(
            f"canonical branch requires a classified Git worktree: {classification.reason}"
        )
    repo_root = classification.repo_root
    for resolver in (_registered_branch, _project_branch, _origin_default_branch):
        branch, source = resolver(repo_root)
        if branch:
            if not _valid_branch(repo_root, branch):
                raise RuntimeError(f"configured canonical branch is invalid: {branch}")
            return {
                "policy": POLICY_VERSION,
                "branch": branch,
                "source": source,
                "repo_root": repo_root,
            }
    raise RuntimeError("origin default or configured canonical branch cannot be resolved")


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
