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

from pr_checkpoint_events import (release_for, released_attempt_token, successors_valid,
                                  timestamp, trusted)

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


def candidate(data, comments, comment, now):
    approval = approved_comment(data, comment, now)
    if approval is None:
        return None
    release = release_for(comments, approval, comment)
    if release is None:
        return None
    closing = (approval["runner"], released_attempt_token(comments, approval, release))
    if not successors_valid({**data, "released_lease": closing}, comments, release["id"],
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
    if release_for(sorted_comments(data), approval, {"id": float("inf")}) is None:
        raise ValueError(
            f"release {approval['release_id']} is not a trusted CLAIM_RELEASED reason=blocked "
            f"by {approval['runner']} closing {approval['attempt']}; dispatch-approved would "
            "reject this approval, so none was generated")
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
