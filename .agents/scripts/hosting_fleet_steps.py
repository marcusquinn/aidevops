#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Idempotent fleet provisioning steps: remote, clone and native init.

Every step re-reads live state first, so a repeat run adopts completed work
instead of repeating it. Without apply, a step only reports what it would do.
Each step returns (status, detail): done, planned or failed.

Repository creation uses only the workspace-exempt form of the shared command
policy (reference/gh-command-discipline.md): a direct private `gh repo create`
with allowlisted options, run inside the projects root, followed by a separate
clone. Init is the native `aidevops init`, which commits in its own linked
worktree and registers the canonical path.
"""

from __future__ import annotations

import os
import subprocess  # nosec B404
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_checks import gh_json, git_value  # noqa: E402
from repo_layout_migrate import load_json, parse_remote  # noqa: E402

INIT_FEATURES = "planning,git-workflow,code-quality"
LONG_TIMEOUT = 1800
Step = tuple[str, str]


def run_long(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> tuple[bool, str]:
    """Run a structured command with a long timeout.

    Returns (ok, last stdout line) on success and (ok, last stderr line) on failure.
    """
    try:
        result = subprocess.run(  # nosec B603
            command, cwd=cwd, env={**os.environ, **(env or {})}, capture_output=True,
            text=True, timeout=LONG_TIMEOUT, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, type(exc).__name__
    ok = result.returncode == 0
    preferred = (result.stdout if ok else result.stderr) or result.stderr or result.stdout or ""
    lines = [line for line in preferred.splitlines() if line.strip()]
    return ok, (lines[-1].strip() if lines else f"exit {result.returncode}")


def remote_step(slug: str, workspace: Path, apply: bool) -> Step:
    """Adopt an existing private repository under the expected owner, or create one."""
    repo, error = gh_json(f"repos/{slug}")
    if isinstance(repo, dict):
        owner = str((repo.get("owner") or {}).get("login") or "")
        if repo.get("private") is True and owner.lower() == slug.split("/", 1)[0].lower():
            return "done", "existing private repository adopted"
        return "failed", "repository exists but is public or under another owner"
    if error != "not-found":
        return "failed", "could not check the remote repository"
    command = ["gh", "repo", "create", slug, "--private", "--add-readme"]
    if not apply:
        return "planned", " ".join(command)
    ok, detail = run_long(command, cwd=workspace)
    return ("done", "created private repository") if ok else ("failed", f"create failed: {detail}")


def clone_step(slug: str, destination: Path, apply: bool) -> Step:
    """Clone into the canonical destination unless the right clone is already there."""
    if destination.exists():
        origin = git_value(destination, "remote", "get-url", "origin") if (destination / ".git").exists() else None
        identity = parse_remote(origin) if origin else None
        if identity and f"{identity[1]}/{identity[2]}".lower() == slug.lower():
            return "done", "existing clone adopted"
        return "failed", "destination exists without this origin"
    command = ["gh", "repo", "clone", slug, str(destination)]
    if not apply:
        return "planned", " ".join(command)
    destination.parent.mkdir(parents=True, exist_ok=True)
    ok, detail = run_long(command, cwd=destination.parent)
    return ("done", "cloned") if ok else ("failed", f"clone failed: {detail}")


def registration(repos_json: Path, slug: str) -> dict[str, Any]:
    """The single registry entry for a slug, or an empty dict."""
    payload = load_json(repos_json) if repos_json.is_file() else {}
    records = payload.get("initialized_repos", []) if isinstance(payload, dict) else []
    matches = [item for item in records if str(item.get("slug") or "").lower() == slug.lower()]
    return matches[0] if len(matches) == 1 else {}


def registered_state(slug: str, destination: Path, repos_json: Path) -> Step | None:
    """Step result when the slug is already registered, else None."""
    entry = registration(repos_json, slug)
    if not entry:
        return None
    if Path(os.path.expanduser(str(entry.get("path") or ""))) == destination:
        return "done", "already registered at the canonical path"
    return "failed", "registered at a different path; resolve with plan/drift first"


def run_init(slug: str, destination: Path, repos_json: Path, command: list[str]) -> Step:
    """Run native init on an existing clone and confirm registration."""
    if not destination.is_dir():
        return "failed", "clone missing"
    # Choice 1: on main, init commits in a linked chore/aidevops-init worktree.
    ok, detail = run_long(command, cwd=destination, env={"AIDEVOPS_PROTECTED_BRANCH_CHOICE": "1"})
    if not ok:
        return "failed", f"init failed: {detail}"
    if not registration(repos_json, slug):
        return "failed", "init finished but the repository is not registered"
    return "done", "initialized and registered"


def init_step(slug: str, destination: Path, repos_json: Path, apply: bool) -> Step:
    """Run native init unless the slug is already registered at the destination."""
    existing = registered_state(slug, destination, repos_json)
    if existing:
        return existing
    command = ["aidevops", "init", INIT_FEATURES]
    if not apply:
        return "planned", " ".join(command)
    return run_init(slug, destination, repos_json, command)
