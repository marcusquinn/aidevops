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
import re
import sys

from pr_checkpoint_events import (EVENTS, events, release_for, released_attempt_token,
                                  successors_valid, timestamp, trusted)
from pr_checkpoint_history import explain_released_successor_history, released_successor_history

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


def blocked_lifecycle(issue):
    return sorted(label["name"] for label in issue.get("labels", [])
                  if label["name"].startswith("status:")) == ["status:blocked"]


def blocked_approval_matches(issue, approval, comment):
    # Normalization must not erase a lifecycle hold imposed after approval.
    # Comments (including our own claim) update the issue too. The shell boundary
    # separately checks lifecycle events against this approval-time snapshot.
    if not blocked_lifecycle(issue):
        return True
    snapshot = approval.get("blocked_issue_updated_at")
    current = issue.get("updated_at")
    return bool(snapshot and current and
                timestamp(snapshot) <= min(timestamp(current), timestamp(comment["created_at"])))


def approved_comment(data, comment, now):
    lines = [line for line in comment["body"].splitlines() if line.startswith(PREFIX)]
    if not trusted(comment, data.get("trusted_logins", ())) or len(lines) != 1:
        return None
    approval = json.loads(lines[0][len(PREFIX):])
    if (not approval_matches(data, approval, comment, now) or
            not blocked_approval_matches(data["issue"], approval, comment)):
        return None
    return approval


def history_approved(data, comments, approval, approval_id, closing):
    trusted_logins = data.get("trusted_logins", ())
    history = released_successor_history(comments, approval["release_id"], approval_id, closing, trusted_logins)
    # Every entry, including claim_only_no_worker and blocked_before_ready
    # (GH#35683) closures, must be acknowledged exactly as generated.
    if history is None or history != approval.get("released_successors", []):
        return False
    historical_claims = {item["claim_id"] for item in history}
    used_tokens = {f.get("lease_token") for c, _, f in
                    events(comments, approval["release_id"], approval_id, trusted_logins)
                   if c["id"] in historical_claims}
    used_tokens.add(closing[1])
    return not data.get("lease") or data["lease"] not in used_tokens


def approved_release(data, comments, approval, comment):
    trusted_logins = data.get("trusted_logins", ())
    release = release_for(comments, approval, comment, trusted_logins)
    if release is None:
        return None
    closing = (release["user"]["login"], released_attempt_token(comments, approval, release, trusted_logins))
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
        allowed_owners = [[], [closing[0]]]
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


def rejection_diagnostic(context):
    """Format metadata only; never echo arbitrary coordination field values."""
    comment, line, state, reason = context
    event = next(kind.strip().replace(" ", "_") for kind in EVENTS if line.startswith(kind))
    actor = comment.get("user", {}).get("login", "")
    runner = actor if re.fullmatch(r"[A-Za-z0-9-]{1,39}(?:\[bot\])?", actor) else "unknown"
    claim = state["claim_id"] if state else "none"
    if reason == "untrusted" and comment.get("updated_at", comment.get("created_at")) != comment.get("created_at"):
        reason = "edited"
    return (f"rejected comment={comment['id']} event={event} runner={runner} "
            f"episode_claim={claim} reason={reason}")


def template(data):
    """Emit an approval line only when dispatch-approved could accept its release.

    GH#33997: an approval naming an unsupported release (for example
    worker_draft_checkpoint or crash_during_execution) can never dispatch, and
    a trusted approval comment also disables the legacy continuation path.
    """
    approval = {**binding(data), "release_id": data["release_id"], "attempt": data["attempt"]}
    if blocked_lifecycle(data["issue"]):
        # This field is emitted only for a blocked approval-time lifecycle.
        updated = data["issue"]["updated_at"]
        timestamp(updated)
        approval["blocked_issue_updated_at"] = updated
    # The approval comment does not exist yet; any later comment id qualifies.
    comments = sorted_comments(data)
    trusted_logins = data.get("trusted_logins", ())
    release = release_for(comments, approval, {"id": float("inf")}, trusted_logins)
    if release is None:
        raise ValueError(
            f"release {approval['release_id']} is not a trusted blocked/clean/worker_complete "
            f"release closing {approval['attempt']} with its poster's ready lease; dispatch-approved would "
            "reject this approval, so none was generated")
    closing = (release["user"]["login"], released_attempt_token(comments, approval, release, trusted_logins))
    history, rejection = explain_released_successor_history(
        comments, release["id"], float("inf"), closing, trusted_logins)
    if history is None:
        raise ValueError("intervening coordination is not fully released; no approval generated; "
                         + rejection_diagnostic(rejection))
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
