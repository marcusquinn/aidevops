# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared field parsing for webhook validation and record derivation."""

from __future__ import annotations

import re
from typing import Any

_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA_RE = re.compile(r"^[A-Fa-f0-9]{40}$")


def _repository_slug(payload: dict[str, Any]) -> str | None:
    repository = payload.get("repository")
    if not isinstance(repository, dict):
        return None
    slug = repository.get("full_name")
    if not isinstance(slug, str) or not _SLUG_RE.fullmatch(slug):
        return None
    owner, name = slug.split("/", 1)
    if not owner[0].isalnum() or owner in {".", ".."} or name in {".", ".."}:
        return None
    return slug


def _pull_number(value: Any) -> int | None:
    if not isinstance(value, dict):
        return None
    number = value.get("number")
    if isinstance(number, int) and number > 0:
        return number
    return None


def _check_sha(event: str, payload: dict[str, Any]) -> str | None:
    sha: Any = None
    if event == "check_suite":
        suite = payload.get("check_suite")
        sha = suite.get("head_sha") if isinstance(suite, dict) else None
    elif event == "check_run":
        check_run = payload.get("check_run")
        if isinstance(check_run, dict):
            sha = check_run.get("head_sha")
            if sha is None and isinstance(check_run.get("check_suite"), dict):
                sha = check_run["check_suite"].get("head_sha")
    elif event == "status":
        sha = payload.get("sha")
    elif event == "workflow_run":
        workflow_run = payload.get("workflow_run")
        sha = workflow_run.get("head_sha") if isinstance(workflow_run, dict) else None
    if not isinstance(sha, str) or not _SHA_RE.fullmatch(sha):
        return None
    return sha.lower()
