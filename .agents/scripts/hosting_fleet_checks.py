#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only per-repository fact collectors for fleet readiness.

Each collector returns (facts, problems, warnings). Problems block readiness;
warnings do not. GitHub access is GET-only through the authenticated gh CLI, and
local checks only query Git and read the untracked project config.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from repo_layout_migrate import MigrationError, git, load_json, parse_remote, run  # noqa: E402

REQUIRED_FEATURES = ("planning", "git_workflow", "code_quality")
WORKER_LABEL = "origin:worker"
Collected = tuple[dict[str, Any], list[str], list[str]]


def gh_json(path: str) -> tuple[Any, str | None]:
    """GET one GitHub API path; return (payload, error kind)."""
    try:
        return json.loads(run(["gh", "api", path])), None
    except MigrationError as exc:
        message = str(exc)
        if "404" in message or "Not Found" in message:
            return None, "not-found"
        if "409" in message or "empty" in message.lower():
            return None, "empty"
        return None, "failed"
    except ValueError:
        return None, "failed"


def remote_facts(slug: str, owner: str) -> Collected:
    """GitHub visibility, owner, permission and default-branch head."""
    repo, error = gh_json(f"repos/{slug}")
    if error or not isinstance(repo, dict):
        return {}, ["remote-missing-or-inaccessible" if error == "not-found" else "remote-check-failed"], []
    permissions = repo.get("permissions") or {}
    facts = {
        "private": repo.get("private"),
        "owner": (repo.get("owner") or {}).get("login"),
        "default_branch": repo.get("default_branch"),
        "archived": repo.get("archived"),
        "admin": permissions.get("admin"),
        "push": permissions.get("push"),
    }
    checks = {
        "remote-not-private": facts["private"] is not True,
        "remote-owner-mismatch": str(facts["owner"] or "").lower() != owner.lower(),
        "remote-archived": bool(facts["archived"]),
        "no-push-permission": not facts["push"],
    }
    problems = [code for code, failed in checks.items() if failed]
    warnings = [] if facts["admin"] or checks["no-push-permission"] else ["no-admin-permission"]
    branch = facts["default_branch"]
    ref, ref_error = gh_json(f"repos/{slug}/git/ref/heads/{branch}") if branch else (None, "empty")
    if ref_error or not isinstance(ref, dict):
        problems.append("remote-default-branch-missing" if ref_error in {"not-found", "empty"}
                        else "remote-check-failed")
    else:
        facts["default_head"] = (ref.get("object") or {}).get("sha")
    return facts, problems, warnings


def git_value(path: Path, *arguments: str) -> str | None:
    """One Git query, or None when it fails."""
    try:
        return git(path, *arguments).strip() or None
    except MigrationError:
        return None


def clone_facts(path: Path, slug: str, remote: dict[str, Any]) -> Collected:
    """Origin identity and remote-tracking default branch of the local clone."""
    if not (path / ".git").exists():
        return {"present": False}, ["clone-missing"], []
    problems: list[str] = []
    warnings: list[str] = []
    origin = git_value(path, "remote", "get-url", "origin")
    identity = parse_remote(origin) if origin else None
    if not identity or f"{identity[1]}/{identity[2]}".lower() != slug.lower():
        problems.append("origin-mismatch")
    facts: dict[str, Any] = {"present": True}
    branch = remote.get("default_branch")
    if branch:
        local_head = git_value(path, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}")
        facts["tracking_head"] = local_head
        if not local_head:
            problems.append("local-default-ref-missing")
        elif remote.get("default_head") and local_head != remote["default_head"]:
            warnings.append("local-default-ref-stale")
        if not git_value(path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"):
            warnings.append("origin-head-missing")
    return facts, problems, warnings


def config_facts(path: Path, registry: dict[str, Any]) -> Collected:
    """Effective features from the local project config, compared with registry labels.

    A missing config is a warning: native gates then use defaults and inferred
    verification, not an opt-out. An explicit false feature is a legacy opt-out
    that disables native gates, so it blocks readiness.
    """
    config_path = path / ".aidevops.json"
    if not config_path.is_file():
        return {"project_config": "missing", "effective_features": "defaults"}, [], ["project-config-missing"]
    try:
        config = load_json(config_path)
    except MigrationError:
        return {"project_config": "invalid"}, ["project-config-invalid"], []
    features = config.get("features") if isinstance(config, dict) else None
    if not isinstance(features, dict):
        return {"project_config": "invalid"}, ["project-config-invalid"], []
    effective = sorted(name for name, value in features.items() if value is True)
    problems = [f"feature-disabled:{name}" for name in REQUIRED_FEATURES if features.get(name) is not True]
    labels = sorted(str(item).replace("-", "_") for item in registry.get("features") or [])
    warnings = [] if set(labels) <= set(effective) else ["registry-features-not-effective"]
    return {"project_config": "present", "effective_features": effective}, problems, warnings


def automation_problems(registry: dict[str, Any]) -> list[str]:
    """Registry flags that keep background automation off."""
    if not registry:
        return ["not-registered"]
    flags = {"pulse-disabled": registry.get("pulse") is not True,
             "maintenance-disabled": registry.get("maintenance") is False}
    return [code for code, failed in flags.items() if failed]


def worker_evidence(slug: str) -> dict[str, Any]:
    """Most recent merged worker PR among the last closed PRs (evidence only)."""
    pulls, error = gh_json(f"repos/{slug}/pulls?state=closed&per_page=50&sort=updated&direction=desc")
    if error or not isinstance(pulls, list):
        return {"status": "unavailable"}
    merged = [
        item.get("merged_at") for item in pulls
        if item.get("merged_at") and any(label.get("name") == WORKER_LABEL for label in item.get("labels") or [])
    ]
    return {"status": "found" if merged else "none-recent", "last_merged_worker_pr": max(merged, default=None)}


def gh_actor() -> str | None:
    """Authenticated GitHub login that Pulse workers inherit."""
    payload, error = gh_json("user")
    return payload.get("login") if not error and isinstance(payload, dict) else None
