#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Authenticated claim/release evidence that consumes checkpoint approvals."""

import re

from pr_checkpoint_events import fields, trusted


def authorizes(comment, logins):
    # Positive edit metadata is supplied by the shared GraphQL collector. REST
    # second-resolution timestamps alone cannot exclude a same-second edit.
    return trusted(comment, logins) and comment.get("_release_body_unedited") is True


def duplicate_keys(line):
    """True when any key repeats, including empty-valued ones fields() drops."""
    keys = re.findall(r"(?:^|\s)([a-z_]+)=", line)
    return len(keys) != len(set(keys))


def authenticated_events(comments, after, prefix, logins):
    """Yield unambiguous events from later, trusted, positively unedited bodies."""
    for comment in comments:
        if comment["id"] <= after or not authorizes(comment, logins):
            continue
        for line in comment["body"].splitlines():
            if line.startswith(prefix) and not duplicate_keys(line):
                yield comment, fields(line)


def release_matches(event, claim_id, nonce):
    """Require an identity and reject every supplied mismatching identity."""
    rel_claim, rel_nonce = event.get("claim_id", ""), event.get("nonce", "")
    if not event.get("reason"):
        return False
    if not rel_claim and not (nonce and rel_nonce):
        return False
    if rel_claim and rel_claim != str(claim_id):
        return False
    if rel_nonce and (not nonce or rel_nonce != nonce):
        return False
    return True


def approval_consumed(comments, approval, logins):
    """Mirror pctl_approval_owns_scheduling in pr-checkpoint-target-lib.sh.

    A claim naming the approval and a later release of that claim, both
    trusted and positively unedited, consume it. Duplicate fields never match,
    so ambiguous evidence keeps the approval fencing.
    """
    for claim, event in authenticated_events(comments, approval["id"], "DISPATCH_CLAIM ", logins):
        if event.get("checkpoint_approval") != str(approval["id"]):
            continue
        releases = authenticated_events(comments, claim["id"], "CLAIM_RELEASED ", logins)
        if any(release_matches(released, claim["id"], event.get("nonce", ""))
               for _, released in releases):
            return True
    return False
