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

from pr_checkpoint_events import EVENTS, fields, normalized_attempt, timestamp, trusted


def require(condition):
    if not condition:
        raise ValueError("invalid automatic checkpoint admission")


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


def authorizes(comment, logins):
    # Positive edit metadata is supplied by the shared GraphQL collector. REST
    # second-resolution timestamps alone cannot exclude a same-second edit.
    return trusted(comment, logins) and comment.get("_release_body_unedited") is True


APPROVAL_TTL_SECONDS = 86400  # pr-checkpoint-revision.py approval_matches


def approval_unexpired(comment, now):
    """Unreadable creation times fail closed: the approval still fences."""
    try:
        return now - timestamp(comment["created_at"]) <= APPROVAL_TTL_SECONDS
    except (AttributeError, KeyError, TypeError, ValueError):
        return True


def own_events(data, comments, claim, claim_fields):
    lease, session = data["lease"], data["session"]
    expiry = int(claim_fields["expires_at"])
    ready_attempt = None
    for comment in comments:
        if comment["id"] <= claim["id"] or not coordination(comment):
            continue
        require(authorizes(comment, data.get("trusted_logins", ())))
        require(comment["user"]["login"] == data["assignee"])
        lines = coordination(comment)
        require(len(lines) == 1 and lines[0].startswith("DISPATCH_LEASE "))
        event = fields(lines[0])
        require(event.get("lease_token") == lease and event.get("session") == session)
        require(event.get("device") == claim_fields.get("device"))
        require(event.get("phase") in {"prelaunch", "ready"})
        if event["phase"] == "ready":
            require(not data.get("claiming") and not data.get("require_prelaunch"))
            attempt = normalized_attempt(event.get("attempt_id"))
            require(bool(attempt) and attempt != "attempt:unknown")
            require(attempt == normalized_attempt(data.get("attempt")))
            require(ready_attempt is None or ready_attempt == attempt)
            ready_attempt = attempt
        else:
            require(ready_attempt is None)
        expiry = int(event["expires_at"])
    now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
    require(expiry > now)


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
    require(not any(line.startswith("CHECKPOINT_CONTINUATION_APPROVED ") and approval_unexpired(comment, now)
                    for comment in comments for line in comment["body"].splitlines()))
    # Never erase edited or foreign coordination while constructing the view.
    require(all(authorizes(comment, logins) for comment in comments if coordination(comment)))
    owners = [actor["login"] for actor in data["issue"].get("assignees", [])]
    statuses = [label["name"] for label in data["issue"]["labels"]
                if label["name"].startswith("status:")]
    require(len(owners) <= 1 and len(statuses) == 1)
    owner, status = (owners[0] if owners else ""), statuses[0][7:]
    lease = data.get("lease", "")
    claim_id = None
    if lease:
        claims = [(comment, fields(line)) for comment in comments for line in coordination(comment)
                  if line.startswith("DISPATCH_CLAIM ") and fields(line).get("nonce") == lease]
        require(len(claims) == 1)
        claim, event = claims[0]
        require(len(coordination(claim)) == 1)
        require(claim["user"]["login"] == data["assignee"] and event.get("runner") == data["assignee"])
        require(event.get("lease_token") == lease and event.get("session") == data["session"])
        require(bool(data.get("device")) and event.get("device") == data["device"])
        require(event.get("phase") == "prelaunch")
        require(event.get("checkpoint_mode") == "automatic" and "checkpoint_approval" not in event)
        previous_owner = event["checkpoint_owner"]
        previous_owner = "" if previous_owner == "none" else previous_owner
        if data.get("claiming"):
            require(owner == previous_owner and status == event["checkpoint_status"])
        else:
            require(owners == [data["assignee"]])
            require(status == "in-progress")
        owner, status = previous_owner, event["checkpoint_status"]
        own_events(data, comments, claim, event)
        claim_id = claim["id"]
        # Keep every non-coordination comment, including later approval/hold
        # evidence. Exclude only the independently verified own episode.
        comments = [comment for comment in comments
                    if comment["id"] < claim_id or not coordination(comment)]
    require(not any(line.startswith("Interactive session claimed")
                    for comment in comments[-1:] for line in coordination(comment)))
    snapshot = binding(data, owner, status, comments)
    digest = seal(snapshot)
    if lease:
        require(event["checkpoint_snapshot"] == digest)
    return {**snapshot, "snapshot": digest, "claim_id": claim_id, "comments": comments}


if __name__ == "__main__":
    try:
        print(json.dumps(admission(json.load(sys.stdin))))
    except (ValueError, KeyError, TypeError, OverflowError):
        sys.exit(1)
