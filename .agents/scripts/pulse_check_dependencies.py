#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dependency consistency diagnostics for the pulse queue scanner."""

from __future__ import annotations

import json
import re
import subprocess
from typing import Any, Optional

NATIVE_ABSENT = "absent"
NATIVE_CLEAR = "clear"
NATIVE_UNKNOWN = "unknown"
NATIVE_UNRESOLVED = "unresolved"
DEPENDENCY_CLAUSE_RE = re.compile(r"blocked[- ]by[^\n\r]*", re.IGNORECASE)
TASK_REF_RE = re.compile(r"\bt([0-9]+(?:\.[0-9a-z]+)*)\b", re.IGNORECASE)
ISSUE_REF_RE = re.compile(r"#([0-9]+)")


def _issue_labels(issue: dict[str, Any]) -> set[str]:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        return set()
    return {str(label.get("name") or "") for label in labels if isinstance(label, dict)}


def _run_gh_json(cmd: list[str]) -> Optional[Any]:
    try:
        completed = subprocess.run(  # nosec B603
            cmd, text=True, capture_output=True, timeout=30, check=False
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
    issue_refs.discard(int(issue.get("number") or 0))
    title_match = re.match(
        r"^t([0-9]+(?:\.[0-9a-z]+)*):", str(issue.get("title") or ""), re.IGNORECASE
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
    issue_state = _issue_refs_state(slug, issue_refs)
    if issue_state != (False, False):
        return issue_state
    return _task_refs_state(slug, issue, task_refs)


def _issue_refs_state(slug: str, issue_refs: set[int]) -> tuple[bool, bool]:
    for blocker in issue_refs:
        payload = _run_gh_json([
            "gh", "issue", "view", str(blocker), "--repo", slug, "--json", "state",
        ])
        if not isinstance(payload, dict):
            return True, True
        if str(payload.get("state") or "").upper() != "CLOSED":
            return True, False
    return False, False


def _task_refs_state(
    slug: str, issue: dict[str, Any], task_refs: set[str]
) -> tuple[bool, bool]:
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


def dependency_diagnostic(slug: str, issue: dict[str, Any]) -> tuple[bool, bool]:
    """Return inconsistency and lookup-error flags for an available issue."""
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
    return _text_dependency_state(slug, issue, labels)
