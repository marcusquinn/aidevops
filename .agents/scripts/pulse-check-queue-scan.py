#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-preserving repos.json auto-dispatch queue scanner."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Any

AGGREGATE_KEY = "aggregate"
ERROR_KEY = "error"
GH_ERRORS_KEY = "gh_errors"
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def _int_from_env(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


def _empty_aggregate() -> dict[str, int]:
    return {
        "repos": 0,
        "auto_dispatch_open": 0,
        "available_unassigned": 0,
        "available_old": 0,
        "oldest_available_age_min": 0,
        "repos_with_available": 0,
        "queued": 0,
        "assigned": 0,
        "blocked_labels": 0,
        "needs_tier": 0,
        "needs_status": 0,
        "parent_task": 0,
        "nmr": 0,
        "no_auto_dispatch": 0,
        GH_ERRORS_KEY: 0,
    }


def _emit(aggregate: dict[str, int], error: str = "", scanned_at: str = "") -> None:
    payload: dict[str, Any] = {AGGREGATE_KEY: aggregate}
    if error:
        payload[ERROR_KEY] = error
    if scanned_at:
        payload["scanned_at"] = scanned_at
    print(json.dumps(payload))


def _issue_labels(issue: dict[str, Any]) -> set[str]:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        return set()
    return {str(label.get("name") or "") for label in labels if isinstance(label, dict)}


def _valid_repo_slug(slug: str) -> bool:
    return bool(REPO_SLUG_RE.fullmatch(slug))


def _issue_age_minutes(issue: dict[str, Any], now: dt.datetime) -> int:
    updated_at = str(issue.get("updatedAt") or "")
    try:
        updated = dt.datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return 0
    return int((now - updated).total_seconds() // 60)


def main() -> int:
    repos_json = pathlib.Path(os.environ.get("PULSE_CHECK_REPOS_JSON", ""))
    skip_gh = os.environ.get("PULSE_CHECK_SKIP_GH", "") in {"1", "true", "TRUE", "yes", "YES"}
    max_issues = _int_from_env("PULSE_CHECK_MAX_ISSUES_PER_REPO", 100)
    old_minutes = _int_from_env("PULSE_CHECK_OLD_AVAILABLE_MINUTES", 30)
    aggregate = _empty_aggregate()

    try:
        data = json.loads(repos_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        _emit(aggregate, f"repos_json_unreadable:{exc.__class__.__name__}")
        return 0

    repos = [
        repo for repo in data.get("initialized_repos", [])
        if repo.get("pulse") is True and not repo.get("local_only") and repo.get("slug")
    ]
    aggregate["repos"] = len(repos)
    if skip_gh:
        _emit(aggregate, "api_cooldown_active")
        return 0
    if shutil.which("gh") is None:
        _emit(aggregate, "gh_missing")
        return 0

    now = dt.datetime.now(dt.timezone.utc)
    blocking_labels = {
        "parent-task",
        "needs-maintainer-review",
        "no-auto-dispatch",
        "hold-for-review",
        "blocked",
        "status:blocked",
        "status:in-review",
    }

    for repo in repos:
        slug = str(repo.get("slug") or "")
        if not _valid_repo_slug(slug):
            aggregate[GH_ERRORS_KEY] += 1
            continue
        cmd = [
            "gh", "issue", "list",
            "--repo", slug,
            "--state", "open",
            "--label", "auto-dispatch",
            "--limit", str(max_issues),
            "--json", "number,title,labels,assignees,updatedAt",
        ]
        try:
            # Fixed argv, shell=False, validated owner/repo slug.
            completed = subprocess.run(  # nosec B603
                cmd,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            aggregate[GH_ERRORS_KEY] += 1
            continue
        if completed.returncode != 0:
            aggregate[GH_ERRORS_KEY] += 1
            continue
        try:
            issues = json.loads(completed.stdout or "[]")
        except json.JSONDecodeError:
            aggregate[GH_ERRORS_KEY] += 1
            continue

        repo_available = 0
        for issue in issues:
            labels = _issue_labels(issue)
            assigned = bool(issue.get("assignees"))
            blocked = bool(labels & blocking_labels)
            aggregate["auto_dispatch_open"] += 1
            aggregate["assigned"] += int(assigned)
            aggregate["queued"] += int("status:queued" in labels)
            aggregate["needs_tier"] += int(not any(label.startswith("tier:") for label in labels))
            aggregate["needs_status"] += int(not any(label.startswith("status:") for label in labels))
            aggregate["blocked_labels"] += int(blocked)
            aggregate["parent_task"] += int("parent-task" in labels)
            aggregate["nmr"] += int("needs-maintainer-review" in labels)
            aggregate["no_auto_dispatch"] += int("no-auto-dispatch" in labels)
            if "status:available" in labels and not assigned and not blocked:
                repo_available += 1
                aggregate["available_unassigned"] += 1
                age_min = _issue_age_minutes(issue, now)
                aggregate["available_old"] += int(age_min >= old_minutes)
                aggregate["oldest_available_age_min"] = max(aggregate["oldest_available_age_min"], age_min)
        aggregate["repos_with_available"] += int(repo_available > 0)

    _emit(aggregate, scanned_at=now.isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main())
