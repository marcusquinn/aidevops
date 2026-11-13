#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate a revision-bound approval against fresh metadata supplied on stdin.

This predicate enforces the authorised brief owner's decision; arbitrary prose,
labels and edited comments grant nothing. Event/lease checks are shared pure
predicates in pr_checkpoint_events.
"""

import datetime as dt
import json
import re
import sys

from pr_checkpoint_binding import PREFIX, binding, binding_diagnostic, sorted_comments
from pr_checkpoint_events import (EVENTS, attempt_owner, events, release_for, released_attempt_token,
                                  successors_valid, timestamp, trusted)
from pr_checkpoint_episodes import TERMINAL_WITHOUT_RELEASE
from pr_checkpoint_history import explain_reviewed_successor_history
from pr_checkpoint_reuse import MAX_NOT_LAUNCHED_REUSES, not_launched_reuse_ids
from pr_checkpoint_unattributed import UNATTRIBUTED

def approval_matches(data, approval, comment, now):
    attempt = approval.get("attempt")
    return all((all(approval.get(key) == value for key, value in binding(data).items()),
                0 <= now - timestamp(comment["created_at"]) <= 86400,
                diagnostic_tooling_valid(approval),
                isinstance(attempt, str) and attempt.startswith("attempt:")))


def diagnostic_tooling_valid(approval):
    """Only a typed, immutable opt-in in the trusted approval grants this scope."""
    if "diagnostic_tooling_commit" not in approval:
        return True
    commit = approval["diagnostic_tooling_commit"]
    return isinstance(commit, str) and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", commit) is not None


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
    proposed = approval.get("released_successors", [])
    terminal_ids = [item["terminal_id"] for item in proposed
                    if item.get("outcome") == TERMINAL_WITHOUT_RELEASE]
    approval_comment = next(c for c in comments if c["id"] == approval_id)
    history, _ = explain_reviewed_successor_history(
        comments, (approval["release_id"], approval_id), closing,
        {"trusted_logins": trusted_logins, "terminal_ids": acknowledgement_ids(terminal_ids),
         "before": timestamp(approval_comment["created_at"])})
    # Every entry, including claim_only_no_worker and blocked_before_ready
    # (GH#35683) closures, must be acknowledged exactly as generated.
    if history is None or history != approval.get("released_successors", []):
        return False
    # GH#36593: an unattributed release has no claim; any token it names is
    # still fenced so a live claim cannot reuse it.
    historical_ids = {item["claim_id"] if "claim_id" in item else item["release_id"] for item in history}
    used_tokens = {f.get("lease_token") for c, _, f in
                    events(comments, approval["release_id"], approval_id, trusted_logins)
                   if c["id"] in historical_ids}
    used_tokens.discard(None)
    used_tokens.add(closing[1])
    return not data.get("lease") or data["lease"] not in used_tokens


def released_lease(comments, approval, release, trusted_logins):
    """(owner, token) of the attempt the release closed; owner is the poster
    except for a stall-class release by another trusted runner (GH#37514)."""
    return (attempt_owner(comments, approval, release, trusted_logins),
            released_attempt_token(comments, approval, release, trusted_logins))


def approved_release(data, comments, approval, comment):
    trusted_logins = data.get("trusted_logins", ())
    release = release_for(comments, approval, comment, trusted_logins)
    if release is None:
        return None
    closing = released_lease(comments, approval, release, trusted_logins)
    return closing if history_approved(data, comments, approval, comment["id"], closing) else None


def candidate_owners_valid(data, closing):
    owners = [a["login"] for a in data["issue"].get("assignees", [])]
    allowed_owners = [[data["assignee"]]]
    if not data.get("lease") or data.get("claiming"):
        allowed_owners = [[], [closing[0]]]
    return owners in allowed_owners


def candidate(data, comments, comment, now):
    approval = approved_comment(data, comment, now)
    if approval is None:
        return None
    closing = approved_release(data, comments, approval, comment)
    if closing is None or not candidate_owners_valid(data, closing):
        return None
    reused = not_launched_reuse_ids(data, comments, comment["id"])
    if reused is None:
        return None
    # The complete earlier history is checked above; the unchanged guard fences
    # only events after the approval and never grants authority from closure.
    later = [c for c in comments if c["id"] >= comment["id"] and c["id"] not in reused]
    if not successors_valid({**data, "released_lease": closing}, later, approval["release_id"],
                            comment["id"], now):
        return None
    return {**approval, "approval_id": comment["id"], "approval_actor": comment["user"]["login"]}


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


def require_unattributed_acknowledgement(history, acknowledged):
    """GH#36593: orphan releases need the maintainer to name each exact comment.

    #aidevops:trust-boundary — automatic callers pass no acknowledgement, so
    they can never approve an orphan. Missing, extra or mismatched IDs refuse.
    """
    orphans = sorted(item["release_id"] for item in history if item.get("outcome") == UNATTRIBUTED)
    if not isinstance(acknowledged, list) or not all(
            isinstance(item, int) and not isinstance(item, bool) for item in acknowledged):
        raise ValueError("acknowledge_unattributed must list comment ids")
    if sorted(acknowledged) == orphans:
        return
    if orphans:
        ids = ",".join(str(item) for item in orphans)
        raise ValueError(
            f"history contains unattributed release comment(s) {ids} with unrecovered provenance; "
            "no approval generated. Inspect them, then rerun approval-template with "
            f"--acknowledge-unattributed={ids} to accept them explicitly")
    raise ValueError("acknowledged comment ids are not unattributed releases in this history; "
                      "no approval generated")


def acknowledgement_ids(value):
    """Reject loose, duplicate or non-comment identifiers before enabling recovery."""
    if (not isinstance(value, list) or any(type(item) is not int or item <= 0 for item in value)
            or len(set(value)) != len(value)):
        raise ValueError("terminal-without-release acknowledgement must list unique positive comment ids")
    return value


def template(data):
    """Emit an approval line only when dispatch-approved could accept its release.

    GH#33997: an approval naming an unsupported release (for example
    worker_draft_checkpoint or crash_during_execution) can never dispatch, and
    a trusted approval comment also disables the legacy continuation path.
    """
    approval = {**binding(data), "release_id": data["release_id"], "attempt": data["attempt"]}
    #aidevops:trust-boundary — no issue prose or default policy enables this opt-in.
    if "diagnostic_tooling_commit" in data:
        if not diagnostic_tooling_valid(data):
            raise ValueError("diagnostic_tooling_commit must be a full lowercase commit id")
        approval["diagnostic_tooling_commit"] = data["diagnostic_tooling_commit"]
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
            f"release {approval['release_id']} is not a trusted blocked/clean/worker_complete release "
            f"closing {approval['attempt']} with its poster's ready lease, or a trusted stall-class release "
            f"closing {approval['attempt']} with one runner's ready lease; dispatch-approved would "
            "reject this approval, so none was generated")
    closing = released_lease(comments, approval, release, trusted_logins)
    terminal_ids = acknowledgement_ids(data.get("acknowledge_terminal_without_release", []))
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    history, rejection = explain_reviewed_successor_history(
        comments, (release["id"], float("inf")), closing,
        {"trusted_logins": trusted_logins, "terminal_ids": terminal_ids, "before": now})
    if history is None:
        raise ValueError("intervening coordination is not fully released; no approval generated; "
                          + rejection_diagnostic(rejection))
    if sorted(terminal_ids) != sorted(item["terminal_id"] for item in history
                                     if item.get("outcome") == TERMINAL_WITHOUT_RELEASE):
        raise ValueError("acknowledged terminal ids do not match terminal-without-release episodes")
    require_unattributed_acknowledgement(history, data.get("acknowledge_unattributed", []))
    if history:
        approval["released_successors"] = history
    return PREFIX + json.dumps(approval)


if __name__ == "__main__":
    template_mode = sys.argv[1:] == ["template"]
    diagnostic_mode = sys.argv[1:] == ["binding-diagnostic"]
    payload = None
    try:
        payload = json.load(sys.stdin)
        if diagnostic_mode:
            print(binding_diagnostic(payload))
            sys.exit(0)
        print(template(payload) if template_mode else json.dumps(validate(payload)))
    except (ValueError, KeyError, TypeError, OverflowError) as error:
        if template_mode:
            print(f"approval-template: {error}", file=sys.stderr)
        elif payload is not None and (diagnostic := binding_diagnostic(payload)):
            print(diagnostic, file=sys.stderr)
        sys.exit(1)
