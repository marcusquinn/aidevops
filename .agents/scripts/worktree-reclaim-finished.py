#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Remove worktrees whose work is provably finished; refuse on any missing evidence.

This is an explicitly opt-in interim pass, not the cleanup evidence collector that
``worker_lifecycle.cleanup_policy.decide_cleanup`` expects. It never claims the six
proofs that policy requires and never reports ``cleanup_authorized``. It answers one
narrower question: has this worktree's work finished, and would removing it lose
anything? Every unreadable or incomplete signal refuses removal.

Removal is deliberately archive-free: the unpushed-work and liveness checks are the
only protection, so each must fail closed.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

SCHEMA = "aidevops.worktree-reclaim-finished/v1"
REFERENCE = re.compile(r"(?:^|[^a-z])(gh|pr)(\d{2,8})(?:[^0-9]|$)")
REMOTE_SLUG = re.compile(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$")


def run(command: list[str], timeout: int = 60) -> tuple[int, str]:
    """Return the exit status and stripped stdout, never raising on failure."""
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return completed.returncode, completed.stdout.strip()


def git(path: Path, *arguments: str) -> tuple[int, str]:
    return run(["git", "-C", str(path), *arguments])


def working_directories() -> set[Path] | None:
    """Resolve every live process working directory, or None when unknowable.

    A missing census is not an absence of writers, so callers must refuse instead
    of treating None as quiescent.
    """
    procfs = Path("/proc")
    if not procfs.is_dir():
        return None
    directories: set[Path] = set()
    observed = False
    for entry in procfs.iterdir():
        if not entry.name.isdigit():
            continue
        observed = True
        try:
            directories.add(Path(os.readlink(entry / "cwd")))
        except OSError:
            # A process that exits mid-scan cannot hold a worktree we then delete,
            # and permission denials are reported by the self-visibility check.
            continue
    if not observed:
        return None
    if Path.cwd() not in directories:
        # The scanner cannot see its own working directory, so it sees no others.
        return None
    return directories


def references(name: str) -> list[tuple[str, int]]:
    """Extract every issue and pull request number encoded in a worktree name."""
    found: list[tuple[str, int]] = []
    for kind, number in REFERENCE.findall(name.lower()):
        entry = (kind, int(number))
        if entry not in found:
            found.append(entry)
    return found


def repository(path: Path) -> str | None:
    status, url = git(path, "remote", "get-url", "origin")
    if status != 0 or not url:
        return None
    match = REMOTE_SLUG.search(url.strip())
    return match.group(1) if match else None


def reference_finished(kind: str, number: int, slug: str, cache: dict) -> tuple[bool, str]:
    """Report whether one reference is finished: issue closed, or pull request merged.

    A pull request closed without merging is not finished work, so only MERGED
    authorizes removal.
    """
    key = (kind, number, slug)
    if key in cache:
        return cache[key]
    if kind == "gh":
        status, output = run(
            ["gh", "issue", "view", str(number), "--repo", slug, "--json", "state"],
        )
        verdict = (False, f"issue-{number}-state-unknown")
        if status == 0 and output:
            state = json.loads(output).get("state")
            verdict = ((state == "CLOSED"), f"issue-{number}-{str(state).lower()}")
    else:
        status, output = run(
            ["gh", "pr", "view", str(number), "--repo", slug, "--json", "state"],
        )
        verdict = (False, f"pr-{number}-state-unknown")
        if status == 0 and output:
            state = json.loads(output).get("state")
            verdict = ((state == "MERGED"), f"pr-{number}-{str(state).lower()}")
    cache[key] = verdict
    return verdict


def nothing_to_lose(path: Path) -> tuple[bool, str]:
    """Confirm no uncommitted, untracked, or unpushed work exists in the worktree."""
    status, dirty = git(path, "status", "--porcelain")
    if status != 0:
        return False, "status-unreadable"
    if dirty:
        return False, "uncommitted-changes"
    status, unpushed = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes")
    if status != 0 or not unpushed.isdigit():
        return False, "unpushed-state-unreadable"
    if int(unpushed) != 0:
        return False, f"unpushed-commits-{unpushed}"
    return True, "nothing-to-lose"


def evidence(path: Path, census: set[Path] | None, cache: dict) -> dict:
    """Decide one worktree, reporting the first missing proof as the reason."""
    verdict: dict = {"path": str(path), "authorized": False, "reason": "unevaluated"}
    if census is None:
        verdict["reason"] = "process-inventory-unavailable"
        return verdict
    if not (path / ".git").exists():
        verdict["reason"] = "not-a-worktree"
        return verdict
    slug = repository(path)
    if slug is None:
        verdict["reason"] = "repository-unknown"
        return verdict
    verdict["repository"] = slug
    found = references(path.name)
    if not found:
        verdict["reason"] = "reference-unknown"
        return verdict
    verdict["references"] = [f"{kind}{number}" for kind, number in found]
    for kind, number in found:
        finished, detail = reference_finished(kind, number, slug, cache)
        if not finished:
            verdict["reason"] = detail
            return verdict
    for directory in census:
        if directory == path or path in directory.parents:
            verdict["reason"] = "writers-present"
            return verdict
    clean, detail = nothing_to_lose(path)
    if not clean:
        verdict["reason"] = detail
        return verdict
    verdict["authorized"] = True
    verdict["reason"] = "work-finished"
    return verdict


def remove(path: Path) -> tuple[bool, str]:
    """Remove one worktree, re-checking liveness immediately before deleting."""
    census = working_directories()
    if census is None:
        return False, "process-inventory-unavailable"
    for directory in census:
        if directory == path or path in directory.parents:
            return False, "writers-appeared"
    status, _ = git(path, "worktree", "remove", "--force", str(path))
    if status != 0 and path.exists():
        try:
            shutil.rmtree(path)
        except OSError as error:
            return False, f"removal-failed-{error.errno}"
    if path.exists():
        return False, "removal-incomplete"
    return True, "removed"


def directory_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path, onerror=lambda _: None):
        for name in files:
            try:
                total += (Path(root) / name).stat(follow_symlinks=False).st_size
            except OSError:
                continue
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-dir", type=Path,
                        default=Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                                                    Path.home() / "Git" / "_worktrees")))
    parser.add_argument("--apply", action="store_true",
                        help="remove authorized worktrees; default reports only")
    parser.add_argument("--budget-seconds", type=int, default=300)
    parser.add_argument("--limit", type=int, default=0, help="0 means no limit")
    arguments = parser.parse_args()
    deadline = time.monotonic() + max(arguments.budget_seconds, 1)
    result: dict = {"schema": SCHEMA, "base_dir": str(arguments.base_dir),
                    "dry_run": not arguments.apply, "scanned": 0, "authorized": 0,
                    "removed": 0, "failed": 0, "refused": 0, "reclaimed_bytes": 0,
                    "budget_exhausted": False, "results": []}
    if not arguments.base_dir.is_dir():
        result["reason"] = "base-dir-absent"
        print(json.dumps(result))
        return 0
    census = working_directories()
    cache: dict = {}
    repositories: set[Path] = set()
    for path in sorted(arguments.base_dir.iterdir()):
        if not path.is_dir():
            continue
        if time.monotonic() >= deadline:
            result["budget_exhausted"] = True
            break
        if arguments.limit and result["scanned"] >= arguments.limit:
            break
        result["scanned"] += 1
        verdict = evidence(path, census, cache)
        if not verdict["authorized"]:
            result["refused"] += 1
            result["results"].append(verdict)
            continue
        result["authorized"] += 1
        verdict["bytes"] = directory_size(path)
        status, common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if not arguments.apply:
            result["results"].append(verdict)
            continue
        removed, detail = remove(path)
        verdict["removal"] = detail
        if removed:
            result["removed"] += 1
            result["reclaimed_bytes"] += verdict["bytes"]
            if status == 0 and common:
                repositories.add(Path(common))
        else:
            result["failed"] += 1
        result["results"].append(verdict)
    for common in repositories:
        run(["git", "--git-dir", str(common), "worktree", "prune"])
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
