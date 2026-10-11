#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deliver a native init commit as a reviewed pull request; never merge.

Pushes the chore/aidevops-init branch from its linked worktree, then opens an
issue and a linked PR through the GitHub write wrapper, so origin labels,
signatures and the linked-issue policy apply. An open PR is reported as
pending: merging belongs to the normal gated lifecycle (full-loop-helper.sh
merge). A closed, unmerged PR is a failure, never retried automatically.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_checks import git_value  # noqa: E402
from hosting_fleet_steps import Step, run_long  # noqa: E402
from repo_layout_migrate import MigrationError, run  # noqa: E402

INIT_BRANCH = "chore/aidevops-init"
ISSUE_TITLE = "Initialize aidevops"
WRITE_HELPER = SCRIPT_DIR / "gh-write-helper.sh"


def init_worktree(clone: Path) -> Path | None:
    """Linked worktree that native init created for its branch."""
    listing = git_value(clone, "worktree", "list", "--porcelain") or ""
    path = None
    for line in listing.splitlines():
        if line.startswith("worktree "):
            path = Path(line[len("worktree "):])
        elif line == f"branch refs/heads/{INIT_BRANCH}":
            return path
    return None


def existing_pr(slug: str) -> dict[str, str] | None:
    """Latest PR (any state) whose head is the init branch."""
    try:
        pulls = json.loads(run(["gh", "pr", "list", "--repo", slug, "--head", INIT_BRANCH,
                                "--state", "all", "--json", "number,state,url", "--limit", "1"]))
    except (MigrationError, ValueError):
        return None
    return pulls[0] if pulls else None


def pr_status(found: dict[str, str]) -> Step:
    """Map an existing init PR to a step status."""
    state = str(found.get("state") or "").upper()
    if state == "MERGED":
        return "done", f"init PR merged: {found.get('url')}"
    if state == "OPEN":
        return "pending", f"init PR open; merge it through the gated lifecycle: {found.get('url')}"
    return "failed", f"init PR closed without merging: {found.get('url')}"


def wrapper(arguments: list[str], body: str, cwd: Path) -> tuple[bool, str]:
    """Run the GitHub write wrapper with an owner-private body file."""
    temp_dir = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
    temp_dir.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="fleet-provision-", suffix=".md", dir=temp_dir)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(body)
        ok, detail = run_long(["bash", str(WRITE_HELPER), *arguments, "--body-file", name], cwd=cwd)
        return ok, detail
    finally:
        os.unlink(name)


def find_issue(slug: str) -> int | None:
    """Open issue titled exactly ISSUE_TITLE (listing, not search: no index lag)."""
    try:
        issues = json.loads(run(["gh", "issue", "list", "--repo", slug, "--state", "open",
                                 "--json", "number,title", "--limit", "200"]))
    except (MigrationError, ValueError):
        return None
    numbers = [int(item["number"]) for item in issues if item.get("title") == ISSUE_TITLE]
    return min(numbers) if numbers else None


def open_issue(slug: str, cwd: Path) -> int | None:
    """Reuse an open init issue or create one; return its number."""
    existing = find_issue(slug)
    if existing:
        return existing
    body = ("## Goal\n\nCommit the native `aidevops init` scaffolding (planning, Git workflow and "
            "code quality) so background workers and Pulse have the standard project files.\n\n"
            "## Verification\n\n`hostinger-helper.sh fleet ready` reports this repository ready.\n")
    ok, _ = wrapper(["issue", "create", "--repo", slug, "--title", ISSUE_TITLE], body, cwd)
    return find_issue(slug) if ok else None


def publish(slug: str, worktree: Path, default_branch: str) -> Step:
    """Push the init branch, then open the issue and its linked PR."""
    ok, detail = run_long(["git", "-C", str(worktree), "push", "-u", "origin", INIT_BRANCH], cwd=worktree)
    if not ok:
        return "failed", f"push failed: {detail}"
    issue = open_issue(slug, worktree)
    if issue is None:
        return "failed", "could not create the init issue"
    body = (f"Commits the native `aidevops init` scaffolding.\n\nResolves #{issue}\n\n"
            "## Verification\n\nInit ran non-interactively; review the scaffolding files before merging.\n")
    ok, detail = wrapper(["pr", "create", "--repo", slug, "--head", INIT_BRANCH, "--base", default_branch,
                          "--title", f"GH#{issue}: chore: initialize aidevops"], body, worktree)
    if not ok:
        return "failed", f"PR creation failed: {detail}"
    return "pending", f"init PR opened; merge it through the gated lifecycle: {detail}"


def deliver_step(slug: str, clone: Path, default_branch: str, apply: bool) -> Step:
    """Push the init branch and open issue + PR; report an existing PR's state."""
    found = existing_pr(slug)
    if found:
        return pr_status(found)
    worktree = init_worktree(clone)
    ahead = git_value(worktree, "rev-list", "--count", f"origin/{default_branch}..{INIT_BRANCH}") if worktree else "0"
    if worktree is None or ahead == "0":
        return "done", "no unpublished init commits"
    if not apply:
        return "planned", f"push {INIT_BRANCH}; open issue and linked PR"
    return publish(slug, worktree, default_branch)
