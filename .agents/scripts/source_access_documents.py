#!/usr/bin/env python3
"""Pure source-access document projection, encoding and identity validation.

No filesystem, credential, network or transaction operations belong here.
The broker loads these bytes from its validated sibling, not Python's search path.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
from typing import Any


class SourceAccessError(RuntimeError):
    """Typed user-facing failure without source content."""


def _require_source(condition: bool, message: str) -> None:
    if not condition:
        raise SourceAccessError(message)


def _require_valid_approval(condition: bool) -> None:
    if not condition:
        raise SourceAccessError("source-access approval is invalid")


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _issue_fields(value: Any, strings: str, nullable: str = "") -> dict[str, Any]:
    _require_source(isinstance(value, dict), "invalid issue snapshot object")
    result = {key: value.get(key) if value.get(key) is not None else "" for key in strings.split()}
    _require_source(all(isinstance(item, str) for item in result.values()), "invalid issue snapshot text")
    result.update({key: value.get(key) for key in nullable.split()})
    _require_source(all(item is None or type(item) in (str, int) for item in result.values()),
                    "invalid issue snapshot scalar")
    return result


def _issue_actor(value: Any) -> dict[str, Any]:
    return _issue_fields(value or {}, "node_id login type", "id")


def _issue_timestamp(value: Any) -> str:
    _require_source(isinstance(value, str) and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is not None,
        "issue evidence has no authoritative timestamp")
    try:
        _require_source(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")) == value,
                        "issue evidence timestamp is invalid")
    except ValueError:
        raise SourceAccessError("issue evidence timestamp is invalid") from None
    return value


def _issue_ignored_comment(comment: dict[str, Any], excluded_id: int | None) -> bool:
    if comment.get("id") == excluded_id or (comment.get("user") or {}).get("type") == "Bot":
        return True
    if comment.get("author_association") not in ("OWNER", "MEMBER", "COLLABORATOR"):
        return False
    body = comment.get("body") or ""
    automatic = (body.startswith("<!-- aidevops-signed-approval -->\n<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — ")
                 and ") -->\nAuto-approved: " in body and ". Stale recovery tick reset." in body)
    claim = re.fullmatch(
        r"<!-- aidevops-interactive-claim/v1 -->\n<!-- ops:start -->\n> Interactive session claimed by @[^\n`]+"
        r"(?: in `[^`\n]+`)? on [^\n]+\.\n> Pulse dispatch blocked via `status:in-review` \+ self-assignment\.\n"
        r"<!-- ops:end -->\n(?:<!-- aidevops:origin:interactive -->\n)?<!-- aidevops:sig -->\n---\n[^\n]+\n?",
        body,
    )
    return automatic or claim is not None


def _issue_comments(comments: list[dict[str, Any]], excluded_id: int | None) -> list[dict[str, Any]]:
    result = []
    for comment in comments:
        _require_source(type(comment.get("id")) is int and comment["id"] > 0, "invalid issue comment identity")
        if _issue_ignored_comment(comment, excluded_id):
            continue
        projected = _issue_fields(comment, "node_id author_association created_at body",
                                  "id path line side commit_id original_commit_id")
        projected.update(source="conversation", author=_issue_actor(comment.get("user")),
                         updated_at=comment.get("updated_at") or comment.get("created_at") or "")
        result.append(projected)
    _require_source(len({item["id"] for item in result}) == len(result), "duplicate issue comment evidence")
    return sorted(result, key=lambda item: item["id"])


def _bound_proposal_id(proposal: dict[str, Any], payload: dict[str, Any]) -> str:
    nonce = proposal.get("nonce")
    digest = proposal.get("issue_snapshot_sha256")
    created = proposal.get("created_at")
    _require_valid_approval(isinstance(nonce, str) and re.fullmatch(r"[a-f0-9]{32}", nonce) is not None)
    _require_valid_approval(type(created) is int and created >= 0)
    _require_valid_approval(type(payload.get("issued_at")) is int and created <= payload["issued_at"])
    _require_valid_approval(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest) is not None)
    _require_valid_approval(payload.get("issue_snapshot_sha256") == digest)
    proposal_id = hashlib.sha256(canonical_json(proposal)).hexdigest()
    _require_valid_approval(payload.get("proposal_id") == proposal_id)
    return proposal_id
