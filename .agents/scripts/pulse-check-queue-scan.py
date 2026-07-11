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
from typing import Any, Optional

AGGREGATE_KEY = "aggregate"
ERROR_KEY = "error"
GH_ERRORS_KEY = "gh_errors"
NATIVE_ABSENT = "absent"
NATIVE_CLEAR = "clear"
NATIVE_UNKNOWN = "unknown"
NATIVE_UNRESOLVED = "unresolved"
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
BLOCKING_LABELS = frozenset({
    "parent-task",
    "needs-maintainer-review",
    "no-auto-dispatch",
    "hold-for-review",
    "blocked",
    "status:blocked",
    "status:in-review",
})
DEPENDENCY_CLAUSE_RE = re.compile(r"blocked[- ]by[^\n\r]*", re.IGNORECASE)
TASK_REF_RE = re.compile(r"\bt([0-9]+(?:\.[0-9a-z]+)*)\b", re.IGNORECASE)
ISSUE_REF_RE = re.compile(r"#([0-9]+)")


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
        "dependency_inconsistent_available": 0,
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


def _load_repos(repos_json: pathlib.Path) -> tuple[list[dict[str, Any]], str]:
    try:
        data = json.loads(repos_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [], f"repos_json_unreadable:{exc.__class__.__name__}"
    if not isinstance(data, dict):
        return [], "repos_json_unreadable:TypeError"
    initialized = data.get("initialized_repos", [])
    if not isinstance(initialized, list):
        return [], ""
    repos = []
    for repo in initialized:
        if not isinstance(repo, dict):
            continue
        if repo.get("pulse") is True and not repo.get("local_only") and repo.get("slug"):
            repos.append(repo)
    return repos, ""


def _fetch_repo_issues(slug: str, max_issues: int) -> Optional[list[dict[str, Any]]]:
    issues: Optional[list[dict[str, Any]]] = None
    cmd = [
        "gh", "issue", "list",
        "--repo", slug,
        "--state", "open",
        "--label", "auto-dispatch",
        "--limit", str(max_issues),
        "--json", "number,title,body,labels,assignees,updatedAt",
    ]
    if _valid_repo_slug(slug):
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
            completed = None
        if completed is not None and completed.returncode == 0:
            try:
                parsed = json.loads(completed.stdout or "[]")
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, list):
                issues = [issue for issue in parsed if isinstance(issue, dict)]
    return issues


def _run_gh_json(cmd: list[str]) -> Optional[Any]:
    try:
        completed = subprocess.run(  # nosec B603
            cmd,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout or "null")
    except json.JSONDecodeError:
        return None


def _native_dependency_state(slug: str, issue_number: int) -> str:
    """Classify native blockers without conflating absence and API uncertainty."""
    owner, repo = slug.split("/", 1)
    query = """
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    issue(number:$number) {
      blockedBy(first:50) { nodes { number state } pageInfo { hasNextPage } }
    }
  }
}
"""
    payload = _run_gh_json([
        "gh", "api", "graphql", "-f", f"query={query}",
        "-F", f"owner={owner}", "-F", f"name={repo}", "-F", f"number={issue_number}",
    ])
    if not isinstance(payload, dict):
        return NATIVE_UNKNOWN
    issue_data = (((payload.get("data") or {}).get("repository") or {}).get("issue") or {})
    blocked_by = issue_data.get("blockedBy") or {}
    nodes = blocked_by.get("nodes")
    page_info = blocked_by.get("pageInfo")
    if not isinstance(nodes, list) or not isinstance(page_info, dict):
        return NATIVE_UNKNOWN
    if page_info.get("hasNextPage") is True:
        return NATIVE_UNKNOWN
    if not nodes:
        return NATIVE_ABSENT
    states = {str(node.get("state") or "").upper() for node in nodes if isinstance(node, dict)}
    return NATIVE_CLEAR if states == {"CLOSED"} else NATIVE_UNRESOLVED


def _declared_dependency_refs(
    issue: dict[str, Any], labels: set[str]
) -> tuple[set[str], set[int]]:
    body = str(issue.get("body") or "")
    clauses = "\n".join(DEPENDENCY_CLAUSE_RE.findall(body))
    task_refs = set(TASK_REF_RE.findall(clauses))
    issue_refs = {int(value) for value in ISSUE_REF_RE.findall(clauses)}
    for label in labels:
        task_match = re.fullmatch(r"blocked-by:t([0-9]+(?:\.[0-9a-z]+)*)", label)
        issue_match = re.fullmatch(r"blocked-by:#([0-9]+)", label)
        if task_match:
            task_refs.add(task_match.group(1))
        if issue_match:
            issue_refs.add(int(issue_match.group(1)))
    issue_number = int(issue.get("number") or 0)
    issue_refs.discard(issue_number)
    title_match = re.match(
        r"^t([0-9]+(?:\.[0-9a-z]+)*):",
        str(issue.get("title") or ""),
        re.IGNORECASE,
    )
    if title_match:
        task_refs.discard(title_match.group(1))
    return task_refs, issue_refs


def _text_dependency_state(
    slug: str, issue: dict[str, Any], labels: set[str]
) -> tuple[bool, bool]:
    task_refs, issue_refs = _declared_dependency_refs(issue, labels)
    if not task_refs and not issue_refs:
        return False, False
    for blocker in issue_refs:
        payload = _run_gh_json([
            "gh", "issue", "view", str(blocker), "--repo", slug, "--json", "state",
        ])
        if not isinstance(payload, dict):
            return True, True
        if str(payload.get("state") or "").upper() != "CLOSED":
            return True, False
    current_number = int(issue.get("number") or 0)
    for task_ref in task_refs:
        matches = _run_gh_json([
            "gh", "issue", "list", "--repo", slug, "--state", "all",
            "--search", f"t{task_ref} in:title", "--limit", "10",
            "--json", "number,title,state",
        ])
        if not isinstance(matches, list):
            return True, True
        canonical = [
            match for match in matches
            if isinstance(match, dict)
            and int(match.get("number") or 0) != current_number
            and re.match(
                rf"^t{re.escape(task_ref)}(?::|\s)",
                str(match.get("title") or ""),
                re.IGNORECASE,
            )
        ]
        if not canonical or any(
            str(match.get("state") or "").upper() != "CLOSED" for match in canonical
        ):
            return True, False
    return False, False


def _dependency_diagnostic(slug: str, issue: dict[str, Any]) -> tuple[bool, bool]:
    labels = _issue_labels(issue)
    if "status:available" not in labels:
        return False, False
    if "status:blocked" in labels:
        return True, False
    native_state = _native_dependency_state(slug, int(issue.get("number") or 0))
    if native_state == NATIVE_UNRESOLVED:
        return True, False
    if native_state == NATIVE_UNKNOWN:
        return True, True
    # Explicit text/TODO-compatible declarations remain repair evidence even
    # when a partial native set is clear; every declared edge must resolve.
    return _text_dependency_state(slug, issue, labels)


def _dependency_inconsistent(slug: str, issue: dict[str, Any]) -> bool:
    inconsistent, _ = _dependency_diagnostic(slug, issue)
    return inconsistent


def _count_issue(
    aggregate: dict[str, int],
    issue: dict[str, Any],
    now: dt.datetime,
    old_minutes: int,
) -> bool:
    labels = _issue_labels(issue)
    assigned = bool(issue.get("assignees"))
    blocked = bool(labels & BLOCKING_LABELS)
    dependency_inconsistent = bool(issue.get("dependency_inconsistent"))
    aggregate["auto_dispatch_open"] += 1
    aggregate["assigned"] += int(assigned)
    aggregate["queued"] += int("status:queued" in labels)
    aggregate["needs_tier"] += int(not any(label.startswith("tier:") for label in labels))
    aggregate["needs_status"] += int(not any(label.startswith("status:") for label in labels))
    aggregate["blocked_labels"] += int(blocked)
    aggregate["dependency_inconsistent_available"] += int(dependency_inconsistent)
    aggregate["parent_task"] += int("parent-task" in labels)
    aggregate["nmr"] += int("needs-maintainer-review" in labels)
    aggregate["no_auto_dispatch"] += int("no-auto-dispatch" in labels)
    available = "status:available" in labels and not assigned and not blocked and not dependency_inconsistent
    if available:
        aggregate["available_unassigned"] += 1
        age_min = _issue_age_minutes(issue, now)
        aggregate["available_old"] += int(age_min >= old_minutes)
        aggregate["oldest_available_age_min"] = max(aggregate["oldest_available_age_min"], age_min)
    return available


def _scan_repo(
    aggregate: dict[str, int],
    repo: dict[str, Any],
    max_issues: int,
    now: dt.datetime,
    old_minutes: int,
) -> None:
    slug = str(repo.get("slug") or "")
    issues = _fetch_repo_issues(slug, max_issues)
    if issues is None:
        aggregate[GH_ERRORS_KEY] += 1
        return
    for issue in issues:
        inconsistent, scan_error = _dependency_diagnostic(slug, issue)
        issue["dependency_inconsistent"] = inconsistent
        aggregate[GH_ERRORS_KEY] += int(scan_error)
    repo_available = sum(int(_count_issue(aggregate, issue, now, old_minutes)) for issue in issues)
    aggregate["repos_with_available"] += int(repo_available > 0)


def main() -> int:
    repos_json = pathlib.Path(os.environ.get("PULSE_CHECK_REPOS_JSON", ""))
    skip_gh = os.environ.get("PULSE_CHECK_SKIP_GH", "") in {"1", "true", "TRUE", "yes", "YES"}
    max_issues = _int_from_env("PULSE_CHECK_MAX_ISSUES_PER_REPO", 100)
    old_minutes = _int_from_env("PULSE_CHECK_OLD_AVAILABLE_MINUTES", 30)
    aggregate = _empty_aggregate()

    repos, load_error = _load_repos(repos_json)
    if load_error:
        _emit(aggregate, load_error)
        return 0
    aggregate["repos"] = len(repos)
    if skip_gh:
        _emit(aggregate, "api_cooldown_active")
        return 0
    if shutil.which("gh") is None:
        _emit(aggregate, "gh_missing")
        return 0

    now = dt.datetime.now(dt.timezone.utc)
    for repo in repos:
        _scan_repo(aggregate, repo, max_issues, now, old_minutes)

    _emit(aggregate, scanned_at=now.isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main())
