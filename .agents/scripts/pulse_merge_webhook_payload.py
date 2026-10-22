# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure GitHub webhook payload validation and record derivation.

Split from pulse-merge-webhook-server.py so the HTTP/ledger boundary stays
separate from payload shape rules. Nothing here performs I/O.
"""

from __future__ import annotations

import re
from typing import Any

_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA_RE = re.compile(r"^[A-Fa-f0-9]{40}$")
_ALLOWED_LABELS = {"auto-dispatch", "coderabbit-nits-ok", "ai-approved"}
_EVENT_ACTIONS = {
    "check_run": {"completed", "created", "requested_action", "rerequested"},
    "check_suite": {"completed", "requested", "rerequested"},
    "issue_comment": {"created", "deleted", "edited"},
    "issues": {
        "assigned",
        "closed",
        "deleted",
        "demilestoned",
        "edited",
        "labeled",
        "locked",
        "milestoned",
        "opened",
        "pinned",
        "reopened",
        "transferred",
        "typed",
        "unassigned",
        "unlabeled",
        "unlocked",
        "unpinned",
        "untyped",
    },
    "pull_request": {
        "assigned",
        "auto_merge_disabled",
        "auto_merge_enabled",
        "closed",
        "converted_to_draft",
        "dequeued",
        "demilestoned",
        "edited",
        "enqueued",
        "labeled",
        "locked",
        "milestoned",
        "opened",
        "ready_for_review",
        "reopened",
        "review_request_removed",
        "review_requested",
        "synchronize",
        "unassigned",
        "unlabeled",
        "unlocked",
    },
    "pull_request_review": {"dismissed", "edited", "submitted"},
    "pull_request_review_comment": {"created", "deleted", "edited"},
    "pull_request_review_thread": {"resolved", "unresolved"},
    "workflow_run": {"completed", "in_progress", "requested"},
}
_STATUS_STATES = {"error", "failure", "pending", "success"}


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


def _attached_pull_numbers(payload: dict[str, Any], key: str) -> list[int]:
    container = payload.get(key)
    if not isinstance(container, dict):
        return []
    pulls = container.get("pull_requests")
    if not isinstance(pulls, list):
        return []
    numbers = {_pull_number(pull) for pull in pulls}
    return sorted(number for number in numbers if number is not None)


def _attached_pulls_are_valid(payload: dict[str, Any], key: str) -> bool:
    container = payload.get(key)
    if not isinstance(container, dict):
        return False
    pulls = container.get("pull_requests", [])
    return isinstance(pulls, list) and all(_pull_number(pull) is not None for pull in pulls)


def _label_payload_is_valid(payload: dict[str, Any]) -> bool:
    label = payload.get("label")
    if not isinstance(label, dict):
        return False
    return isinstance(label.get("name"), str)


def _issue_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _pull_number(payload.get("issue")) is None:
        return False
    if event != "issues":
        return True
    if payload.get("action") not in {"labeled", "unlabeled"}:
        return True
    return _label_payload_is_valid(payload)


def _review_payload_is_valid(payload: dict[str, Any]) -> bool:
    review = payload.get("review")
    if not isinstance(review, dict):
        return False
    if payload.get("action") != "submitted":
        return True
    return str(review.get("state", "")).lower() in {
        "approved",
        "changes_requested",
        "commented",
        "dismissed",
        "pending",
    }


def _pull_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _pull_number(payload.get("pull_request")) is None:
        return False
    if event == "pull_request_review":
        return _review_payload_is_valid(payload)
    if event != "pull_request":
        return True
    if payload.get("action") not in {"labeled", "unlabeled"}:
        return True
    return _label_payload_is_valid(payload)


def _check_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _check_sha(event, payload) is None:
        return False
    return _attached_pulls_are_valid(payload, event)


def _status_event_payload_is_valid(_event: str, payload: dict[str, Any]) -> bool:
    if payload.get("state") not in _STATUS_STATES:
        return False
    return _check_sha("status", payload) is not None


def _workflow_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    return _check_sha(event, payload) is not None


_EVENT_PAYLOAD_VALIDATORS = {
    "check_run": _check_event_payload_is_valid,
    "check_suite": _check_event_payload_is_valid,
    "issue_comment": _issue_event_payload_is_valid,
    "issues": _issue_event_payload_is_valid,
    "pull_request": _pull_event_payload_is_valid,
    "pull_request_review": _pull_event_payload_is_valid,
    "pull_request_review_comment": _pull_event_payload_is_valid,
    "pull_request_review_thread": _pull_event_payload_is_valid,
    "status": _status_event_payload_is_valid,
    "workflow_run": _workflow_event_payload_is_valid,
}


def _event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _repository_slug(payload) is None:
        return False
    if event != "status" and payload.get("action") not in _EVENT_ACTIONS.get(event, set()):
        return False
    validator = _EVENT_PAYLOAD_VALIDATORS.get(event)
    if validator is None:
        return False
    return validator(event, payload)


def _successful_check_pull_numbers(event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "completed":
        return []
    check = payload.get(event)
    if not isinstance(check, dict):
        return []
    if check.get("conclusion") != "success":
        return []
    return _attached_pull_numbers(payload, event)


def _review_process_pull_numbers(_event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "submitted":
        return []
    review = payload.get("review")
    if not isinstance(review, dict):
        return []
    if str(review.get("state", "")).lower() not in {"approved", "changes_requested"}:
        return []
    number = _pull_number(payload.get("pull_request"))
    if number is None:
        return []
    return [number]


def _label_process_pull_numbers(_event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "labeled":
        return []
    label = payload.get("label")
    if not isinstance(label, dict) or label.get("name") not in _ALLOWED_LABELS:
        return []
    number = _pull_number(payload.get("pull_request"))
    if number is None:
        return []
    return [number]


_PROCESS_PR_RESOLVERS = {
    "check_run": _successful_check_pull_numbers,
    "check_suite": _successful_check_pull_numbers,
    "pull_request": _label_process_pull_numbers,
    "pull_request_review": _review_process_pull_numbers,
}


def _process_pr_actions(event: str, payload: dict[str, Any]) -> list[tuple[str, int]]:
    slug = _repository_slug(payload)
    if slug is None:
        return []
    resolver = _PROCESS_PR_RESOLVERS.get(event)
    if resolver is None:
        return []
    numbers = resolver(event, payload)
    return [(slug, number) for number in numbers]


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


def _invalidation_records(
    event: str, payload: dict[str, Any], protocol: str
) -> list[str]:
    slug = _repository_slug(payload)
    if slug is None:
        return []
    records: list[str] = []
    if event == "issues":
        records.append(f"INVALIDATE {protocol} collection issues {slug}")
    elif event == "issue_comment":
        issue = payload.get("issue")
        kind = "prs" if isinstance(issue, dict) and "pull_request" in issue else "issues"
        records.append(f"INVALIDATE {protocol} collection {kind} {slug}")
    elif event in {
        "pull_request",
        "pull_request_review",
        "pull_request_review_comment",
        "pull_request_review_thread",
    }:
        records.append(f"INVALIDATE {protocol} collection prs {slug}")
    elif event in {"check_run", "check_suite", "status", "workflow_run"}:
        sha = _check_sha(event, payload)
        if sha is not None:
            records.append(f"INVALIDATE {protocol} checks {slug} {sha}")
    return records
