#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure authenticated coordination-event predicates for checkpoint recovery."""

import re

from pr_checkpoint_event_fields import (
    EVENTS as EVENTS,
    TRUSTED as TRUSTED,
    author_trusted as author_trusted,
    events as events,
    fields as fields,
    normalized_attempt as normalized_attempt,
    timestamp as timestamp,
    trusted as trusted,
)

# Preserve the public parsing API while keeping its implementation separate.
__all__ = (
    "EVENTS", "TRUSTED", "author_trusted", "events", "fields",
    "normalized_attempt", "timestamp", "trusted", "ready_leases",
    "original_lease", "intervening_event_bound", "intervening_events_valid",
    "CHECKPOINT_RELEASE_REASONS", "checkpoint_release_fields", "release_for",
    "own_claim_matches", "own_renewal_matches", "released_attempt_token",
    "closes_released_attempt", "successors_valid", "STALL_RELEASE_REASONS",
    "STALL_RELEASE_PATTERN", "release_reason", "stall_release", "attempt_owner",
)


def release_reason(release):
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    return fields(lines[0]).get("reason", "") if len(lines) == 1 else ""


def stall_release(release):
    """GH#37514: stall-class releases record no worker decision about the draft."""
    reason = release_reason(release)
    return reason in STALL_RELEASE_REASONS or bool(STALL_RELEASE_PATTERN.fullmatch(reason))


def attempt_owner(comments, approval, release, trusted_logins=()):
    """Return the login whose ready lease this release closes, or None.

    #aidevops:trust-boundary — blocked and completed exits must close the
    poster's own ready lease. A stall-class release is posted by whichever
    trusted runner observed the stall (for example a stale-assignment reset), so
    the attempt owner is the single login with a ready lease for that attempt;
    several candidate logins, including edited leases, refuse.
    """
    poster = release["user"]["login"]
    if not stall_release(release):
        return poster
    owners = {comment["user"]["login"] for comment, line, f in
              events(comments, -1, release["id"], trusted_logins)
              if line.startswith("DISPATCH_LEASE ") and f.get("phase") == "ready"
              and normalized_attempt(f.get("attempt_id")) == approval["attempt"]}
    return next(iter(owners)) if len(owners) == 1 else None


def ready_leases(comments, approval, release, trusted_logins=()):
    ready = []
    owner = attempt_owner(comments, approval, release, trusted_logins)
    for comment, line, f in events(comments, -1, release["id"], trusted_logins):
        if not trusted(comment, trusted_logins) or owner is None or comment["user"]["login"] != owner:
            continue
        if (line.startswith("DISPATCH_LEASE ")
                and normalized_attempt(f.get("attempt_id")) == approval["attempt"]
                and f.get("phase") == "ready"):
            ready.append((comment["id"], f))
    return ready


def original_lease(comments, approval, release, released, trusted_logins=()):
    ready = ready_leases(comments, approval, release, trusted_logins)
    tokens = {f.get("lease_token") for _, f in ready}
    if len(tokens) != 1 or not next(iter(tokens)):
        return False
    token = next(iter(tokens))
    if released.get("lease_token", token) != token:
        return False
    if normalized_attempt(released.get("attempt_id", approval["attempt"])) != approval["attempt"]:
        return False
    between = events(comments, ready[-1][0], release["id"], trusted_logins)
    return intervening_events_valid(between, attempt_owner(comments, approval, release, trusted_logins),
                                    token, approval["attempt"], trusted_logins)


def intervening_event_bound(comment, line, f, binding, trusted_logins=()):
    runner, token, attempt = binding
    if line.startswith("Dispatching worker"):
        f = fields(comment["body"])
    return all((trusted(comment, trusted_logins), comment["user"]["login"] == runner,
                f.get("lease_token") == token, not line.startswith("DISPATCH_CLAIM "),
                normalized_attempt(f.get("attempt_id", attempt)) == attempt))


def intervening_events_valid(between, runner, token, attempt, trusted_logins=()):
    # Even a legacy release cannot terminate another attempt that intervened
    # after the approved attempt's ready lease.
    binding = (runner, token, attempt)
    return all(intervening_event_bound(comment, line, f, binding, trusted_logins)
               for comment, line, f in between)


CHECKPOINT_RELEASE_REASONS = {"blocked", "clean", "worker_complete"}
# GH#37514: stall-class releases (pr-checkpoint-continuation-helper.sh
# _PCC_STALL_RELEASE_PATTERN, minus worker decisions and the push/network policy
# terminal-blocker classes) also leave the preserved draft without a recorded
# decision, so a maintainer may approve resuming their exact head.
STALL_RELEASE_REASONS = frozenset({
    "no_activity", "wall_clock_stale", "stale_assignment_reset", "worker_ownership_lost",
    "worker_noop_zero_output", "worker_incomplete_exit"})
STALL_RELEASE_PATTERN = re.compile(
    r"(?!(?:push|network)_policy_timeout$)"
    r"(?:watchdog_kill:[A-Za-z0-9_.:-]+|[a-z0-9_]*_stall|[a-z0-9_]*timeout[a-z0-9_]*)")


def checkpoint_release_fields(release, checkpoint_author):
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    released = fields(lines[0]) if len(lines) == 1 else {}
    reason = released.get("reason")
    poster = release["user"]["login"]
    #aidevops:trust-boundary — completed exits grant nothing by themselves. The
    # poster must authenticate their own ready lease, never the PR author's lease;
    # a blocked release must also be the checkpoint author's own. A stall-class
    # release must name its own poster; attempt_owner binds the closed lease.
    supported = reason in CHECKPOINT_RELEASE_REASONS or stall_release(release)
    valid = all((supported, released.get("runner") == poster,
                 reason != "blocked" or poster == checkpoint_author))
    return released if valid else None


def release_for(comments, approval, approval_comment, trusted_logins=()):
    matches = [c for c in comments if c["id"] == approval.get("release_id")]
    if len(matches) != 1:
        return None
    release = matches[0]
    identity_valid = trusted(release, trusted_logins) and release["id"] < approval_comment["id"]
    released = checkpoint_release_fields(release, approval["runner"])
    if not identity_valid or released is None:
        return None
    return release if original_lease(comments, approval, release, released, trusted_logins) else None


def own_claim_matches(data, approval_id, comment, line, f):
    expected = {"nonce": data.get("lease"), "lease_token": data.get("lease"),
                "checkpoint_approval": str(approval_id), "session": data.get("session"),
                "runner": data.get("assignee")}
    return all((bool(data.get("lease")), line.startswith("DISPATCH_CLAIM "),
                f.get("checkpoint_mode", "revision") == "revision",
                all(f.get(key) == value for key, value in expected.items()),
                data.get("assignee") == comment["user"]["login"]))


def own_renewal_matches(claim, comment, line, f):
    if not claim:
        return False
    return all((line.startswith("DISPATCH_LEASE "),
                f.get("lease_token") == claim.get("lease_token"),
                f.get("session") == claim.get("session"),
                comment["user"]["login"] == claim.get("runner"),
                f.get("phase") in {"prelaunch", "ready"}))


def released_attempt_token(comments, approval, release, trusted_logins=()):
    tokens = {f.get("lease_token") for _, f in ready_leases(comments, approval, release, trusted_logins)}
    return next(iter(tokens)) if len(tokens) == 1 else None


def closes_released_attempt(released_lease, comment, line, f):
    # GH#33839: the released attempt closes its own lease after CLAIM_RELEASED;
    # that terminal lease ends the old attempt and is not a successor owner.
    runner, token = released_lease or (None, None)
    return all((bool(token), line.startswith("DISPATCH_LEASE "), f.get("phase") == "terminal",
                f.get("lease_token") == token, comment["user"]["login"] == runner))


def successors_valid(data, comments, release_id, approval_id, now):
    claim = None
    trusted_logins = data.get("trusted_logins", ())
    for comment, line, f in events(comments, release_id, float("inf"), trusted_logins):
        if not trusted(comment, trusted_logins):
            return False
        if closes_released_attempt(data.get("released_lease"), comment, line, f):
            continue
        if claim is None and own_claim_matches(data, approval_id, comment, line, f):
            claim = f
        elif own_renewal_matches(claim, comment, line, f):
            if data.get("require_prelaunch") and f.get("phase") != "prelaunch":
                return False
            claim = {**claim, **f}
        else:
            return False
    return not data.get("lease") or bool(claim and int(claim.get("expires_at", 0)) > now)
