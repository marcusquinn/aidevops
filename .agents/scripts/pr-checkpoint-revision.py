#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate a revision-bound approval against fresh metadata supplied on stdin.

This predicate enforces the authorised brief owner's decision; arbitrary prose,
labels and edited comments grant nothing. Event/lease checks are shared pure
predicates in pr_checkpoint_events.
"""

import datetime as dt
import hashlib
import json
import sys

from pr_checkpoint_events import (events, release_for, released_attempt_token,
                                  successors_valid, timestamp, trusted)
from pr_checkpoint_history import released_successor_history

PREFIX = "CHECKPOINT_CONTINUATION_APPROVED "


def binding(data):
    issue, pr = data["issue"], data["pr"]
    return {"repo": data["repo"], "issue": issue["number"], "pr": pr["number"],
            "head": pr["headRefOid"], "ref": pr["headRefName"],
            "runner": pr["author"]["login"],
            "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}


def approval_matches(data, approval, comment, now):
    attempt = approval.get("attempt")
    return all((all(approval.get(key) == value for key, value in binding(data).items()),
                0 <= now - timestamp(comment["created_at"]) <= 86400,
                isinstance(attempt, str) and attempt.startswith("attempt:")))


def approved_comment(data, comment, now):
    lines = [line for line in comment["body"].splitlines() if line.startswith(PREFIX)]
    if not trusted(comment) or len(lines) != 1:
        return None
    approval = json.loads(lines[0][len(PREFIX):])
    if not approval_matches(data, approval, comment, now):
        return None
    return approval


def history_approved(data, comments, approval, approval_id, closing):
    history = released_successor_history(comments, approval["release_id"], approval_id, closing)
    if history is None or history != approval.get("released_successors", []):
        return False
    historical_claims = {item["claim_id"] for item in history}
    used_tokens = {f.get("lease_token") for c, _, f in
                   events(comments, approval["release_id"], approval_id)
                   if c["id"] in historical_claims}
    used_tokens.add(closing[1])
    return not data.get("lease") or data["lease"] not in used_tokens


def approved_release(data, comments, approval, comment):
    release = release_for(comments, approval, comment)
    if release is None:
        return None
    closing = (approval["runner"], released_attempt_token(comments, approval, release))
    return closing if history_approved(data, comments, approval, comment["id"], closing) else None


def candidate(data, comments, comment, now):
    approval = approved_comment(data, comment, now)
    if approval is None:
        return None
    closing = approved_release(data, comments, approval, comment)
    if closing is None:
        return None
    # The complete earlier history is checked above; the unchanged guard fences
    # only events after the approval and never grants authority from closure.
    later = [c for c in comments if c["id"] >= comment["id"]]
    if not successors_valid({**data, "released_lease": closing}, later, approval["release_id"],
                            comment["id"], now):
        return None
    owners = [a["login"] for a in data["issue"].get("assignees", [])]
    allowed_owners = [[data["assignee"]]]
    if not data.get("lease") or data.get("claiming"):
        allowed_owners = [[], [approval["runner"]]]
    if owners not in allowed_owners:
        return None
    return {**approval, "approval_id": comment["id"], "approval_actor": comment["user"]["login"]}


def sorted_comments(data):
    comments = data["comments"]
    if comments and isinstance(comments[0], list):
        comments = [c for page in comments for c in page]
    return sorted(comments, key=lambda c: (c["created_at"], c["id"]))


def validate(data):
    comments = sorted_comments(data)
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    candidates = [result for c in comments if (result := candidate(data, comments, c, now)) is not None]
    if len(candidates) != 1:
        raise ValueError("missing or ambiguous current revision approval")
    return candidates[0]


def template(data):
    """Emit an approval line only when dispatch-approved could accept its release.

    GH#33997: an approval naming a non-blocked release (for example
    worker_draft_checkpoint or crash_during_execution) can never dispatch, and
    a trusted approval comment also disables the legacy continuation path.
    """
    approval = {**binding(data), "release_id": data["release_id"], "attempt": data["attempt"]}
    # The approval comment does not exist yet; any later comment id qualifies.
    comments = sorted_comments(data)
    release = release_for(comments, approval, {"id": float("inf")})
    if release is None:
        raise ValueError(
            f"release {approval['release_id']} is not a trusted CLAIM_RELEASED reason=blocked "
            f"by {approval['runner']} closing {approval['attempt']}; dispatch-approved would "
            "reject this approval, so none was generated")
    closing = (approval["runner"], released_attempt_token(comments, approval, release))
    history = released_successor_history(comments, release["id"], float("inf"), closing)
    if history is None:
        raise ValueError("intervening coordination is not fully released; no approval generated")
    if history:
        approval["released_successors"] = history
    return PREFIX + json.dumps(approval)


if __name__ == "__main__":
    template_mode = sys.argv[1:] == ["template"]
    try:
        payload = json.load(sys.stdin)
        print(template(payload) if template_mode else json.dumps(validate(payload)))
    except (ValueError, KeyError, TypeError, OverflowError) as error:
        if template_mode:
            print(f"approval-template: {error}", file=sys.stderr)
        sys.exit(1)
