#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bind automatic checkpoint admission to an actual claim, never an approval.

Metadata eligibility remains in pr-checkpoint-target-lib.sh. This predicate
separates the frozen pre-claim evidence from the caller's own live claim and
renewals; it does not reconcile or remove historical coordination records.
"""

import datetime as dt
import hashlib
import json
import sys

from pr_checkpoint_consumption import approval_consumed, authorizes
from pr_checkpoint_events import EVENTS, author_trusted, fields, normalized_attempt, timestamp


class AdmissionRejected(ValueError):
    """Refusal carrying one fixed reason; never lease, nonce, device or session values."""

    def __init__(self, reason):
        super().__init__("invalid automatic checkpoint admission")
        self.reason = reason if reason in REASONS else "invalid"


# GH#40297: bounded stderr diagnostics for callers that discard stdout.
REASONS = frozenset({
    "invalid", "approval_owns_scheduling", "untrusted_coordination", "issue_lifecycle_ambiguous",
    "claim_not_unique", "claim_identity_mismatch", "issue_state_changed", "later_foreign_coordination",
    "later_non_lease_coordination", "later_lease_mismatch", "ready_attempt_mismatch", "lease_expired",
    "interactive_claim_newest", "snapshot_changed",
})


def require(condition, reason="invalid"):
    if not condition:
        raise AdmissionRejected(reason)


def coordination(comment):
    return [line for line in comment["body"].splitlines() if line.startswith(EVENTS)]


def binding(data, owner, status, comments):
    pr, issue = data["pr"], data["issue"]
    history = [{**{key: comment.get(key) for key in ("id", "body", "author_association", "created_at")},
                "actor": comment["user"]["login"]}
               for comment in comments if coordination(comment)]
    require("body" in issue and (issue["body"] is None or isinstance(issue["body"], str)))
    return {"policy": "automatic-checkpoint-v1", "repo": data["repo"], "issue": issue["number"], "pr": pr["number"],
            "head": pr["headRefOid"], "ref": pr["headRefName"],
            "author": pr["author"]["login"], "previous_assignee": owner,
            "previous_status": status, "history_sha256": seal(history),
            "issue_labels": sorted(label["name"] for label in issue["labels"]
                                   if not label["name"].startswith("status:")),
            "pr_labels": sorted(label["name"] for label in pr["labels"]),
            "brief_sha256": hashlib.sha256((issue["body"] or "").encode()).hexdigest()}


def seal(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


APPROVAL_TTL_SECONDS = 86400  # pr-checkpoint-revision.py approval_matches


def approval_unexpired(comment, now):
    """Unreadable creation times fail closed: the approval still fences."""
    try:
        return now - timestamp(comment["created_at"]) <= APPROVAL_TTL_SECONDS
    except (AttributeError, KeyError, TypeError, ValueError):
        return True


def has_line(comment, prefix):
    return any(line.startswith(prefix) for line in comment["body"].splitlines())


def blocking_approvals(comments, logins, now):
    """Unexpired approvals that still own scheduling (consumed ones do not)."""
    approvals = [c for c in comments if has_line(c, "CHECKPOINT_CONTINUATION_APPROVED ")
                 and approval_unexpired(c, now)]
    trusted_ids = [c["id"] for c in comments if has_line(c, "CHECKPOINT_CONTINUATION_APPROVED ")
                   and author_trusted(c, logins)]
    latest = max(trusted_ids, default=None)
    if latest is not None:
        newest = next(c for c in comments if c["id"] == latest)
        if approval_unexpired(newest, now) and approval_consumed(comments, newest, logins):
            # Older trusted approvals are superseded; untrusted ones still fence.
            return [c for c in approvals if c["id"] != latest
                    and not author_trusted(c, logins)]
    return approvals


def own_events(data, comments, claim, claim_fields):
    lease, session = data["lease"], data["session"]
    expiry = int(claim_fields["expires_at"])
    ready_attempt = None
    for comment in comments:
        if comment["id"] <= claim["id"] or not coordination(comment):
            continue
        require(authorizes(comment, data.get("trusted_logins", ())), "later_foreign_coordination")
        require(comment["user"]["login"] == data["assignee"], "later_foreign_coordination")
        lines = coordination(comment)
        # GH#40297: stays strict; the dispatcher releases its own orphans before claiming.
        require(len(lines) == 1 and lines[0].startswith("DISPATCH_LEASE "), "later_non_lease_coordination")
        event = fields(lines[0])
        require(event.get("lease_token") == lease and event.get("session") == session, "later_lease_mismatch")
        require(event.get("device") == claim_fields.get("device"), "later_lease_mismatch")
        require(event.get("phase") in {"prelaunch", "ready"}, "later_lease_mismatch")
        if event["phase"] == "ready":
            require(not data.get("claiming") and not data.get("require_prelaunch"), "ready_attempt_mismatch")
            attempt = normalized_attempt(event.get("attempt_id"))
            require(bool(attempt) and attempt != "attempt:unknown", "ready_attempt_mismatch")
            require(attempt == normalized_attempt(data.get("attempt")), "ready_attempt_mismatch")
            require(ready_attempt is None or ready_attempt == attempt, "ready_attempt_mismatch")
            ready_attempt = attempt
        else:
            require(ready_attempt is None, "ready_attempt_mismatch")
        expiry = int(event["expires_at"])
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    require(expiry > now, "lease_expired")


def admission(data):
    comments = data["comments"]
    if comments and isinstance(comments[0], list):
        comments = [comment for page in comments for comment in page]
    comments = sorted(comments, key=lambda comment: comment["id"])
    logins = data.get("trusted_logins", ())
    # A recorded revision request is never interpreted as automatic admission,
    # even if edited, malformed or permission evidence is unavailable. GH#37779:
    # once it is past the 24-hour revision expiry it no longer owns scheduling,
    # so the legacy automatic route may admit again.
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    require(not blocking_approvals(comments, logins, now), "approval_owns_scheduling")
    # Never erase edited or foreign coordination while constructing the view.
    require(all(authorizes(comment, logins) for comment in comments if coordination(comment)),
            "untrusted_coordination")
    owners = [actor["login"] for actor in data["issue"].get("assignees", [])]
    statuses = [label["name"] for label in data["issue"]["labels"]
                if label["name"].startswith("status:")]
    require(len(owners) <= 1 and len(statuses) == 1, "issue_lifecycle_ambiguous")
    owner, status = (owners[0] if owners else ""), statuses[0][7:]
    lease = data.get("lease", "")
    claim_id = None
    if lease:
        claims = [(comment, fields(line)) for comment in comments for line in coordination(comment)
                  if line.startswith("DISPATCH_CLAIM ") and fields(line).get("nonce") == lease]
        require(len(claims) == 1, "claim_not_unique")
        claim, event = claims[0]
        require(len(coordination(claim)) == 1, "claim_identity_mismatch")
        require(claim["user"]["login"] == data["assignee"] and event.get("runner") == data["assignee"],
                "claim_identity_mismatch")
        require(event.get("lease_token") == lease and event.get("session") == data["session"],
                "claim_identity_mismatch")
        require(bool(data.get("device")) and event.get("device") == data["device"], "claim_identity_mismatch")
        require(event.get("phase") == "prelaunch", "claim_identity_mismatch")
        require(event.get("checkpoint_mode") == "automatic" and "checkpoint_approval" not in event,
                "claim_identity_mismatch")
        previous_owner = event["checkpoint_owner"]
        previous_owner = "" if previous_owner == "none" else previous_owner
        if data.get("claiming"):
            require(owner == previous_owner and status == event["checkpoint_status"], "issue_state_changed")
        else:
            require(owners == [data["assignee"]], "issue_state_changed")
            require(status == "in-progress", "issue_state_changed")
        owner, status = previous_owner, event["checkpoint_status"]
        own_events(data, comments, claim, event)
        claim_id = claim["id"]
        # Keep every non-coordination comment, including later approval/hold
        # evidence. Exclude only the independently verified own episode.
        comments = [comment for comment in comments
                    if comment["id"] < claim_id or not coordination(comment)]
    require(not any(line.startswith("Interactive session claimed")
                    for comment in comments[-1:] for line in coordination(comment)), "interactive_claim_newest")
    snapshot = binding(data, owner, status, comments)
    digest = seal(snapshot)
    if lease:
        require(event["checkpoint_snapshot"] == digest, "snapshot_changed")
    return {**snapshot, "snapshot": digest, "claim_id": claim_id, "comments": comments}


if __name__ == "__main__":
    try:
        print(json.dumps(admission(json.load(sys.stdin))))
    except (ValueError, KeyError, TypeError, OverflowError) as error:
        reason = error.reason if isinstance(error, AdmissionRejected) else "malformed_input"
        print(f"PR_CHECKPOINT_ADMISSION_REJECTED reason={reason}", file=sys.stderr)
        sys.exit(1)
