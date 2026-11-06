#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconstruct fully released historical attempts without granting ownership."""

import hashlib
import json

from pr_checkpoint_events import closes_released_attempt, events, fields, normalized_attempt, trusted
from pr_checkpoint_episodes import acknowledged_terminal, completed_episode
from pr_checkpoint_never_ready import (CLAIM_ONLY,
                                       advance_never_ready_release, close_claim_only)
from pr_checkpoint_unattributed import unattributed_release


def closed_claim(comment, line, f, seen):
    """Start one sequential historical attempt, never an interactive owner."""
    actor = comment["user"]["login"]
    token = f.get("lease_token")
    if not all((line.startswith("DISPATCH_CLAIM "), bool(token), token not in seen,
                f.get("nonce") == token, f.get("runner") == actor, bool(f.get("session")),
                f.get("phase", "prelaunch") == "prelaunch")):
        return None
    seen.add(token)
    return {"runner": actor, "token": token, "session": f["session"], "claim_id": comment["id"]}


def close_release(state, comment, f):
    if not state.get("attempt") or not state.get("ready_id"):
        return False
    valid = all((not state.get("release_id"), bool(f.get("reason")),
                 f.get("runner") == state["runner"],
                 f.get("lease_token", state["token"]) == state["token"],
                 normalized_attempt(f.get("attempt_id", state["attempt"])) == state["attempt"]))
    if valid:
        state["release_id"] = comment["id"]
    return valid


def lease_attempt_accepted(state, f, attempt):
    """Bind every lease to one attempt, allowing one rebind at the first ready lease.

    #aidevops:trust-boundary — GH#36005: a manual-dispatch worker launched through
    a managed unit could not inherit the dispatcher's attempt ID, so its ready
    lease names a fresh attempt. The rebind is accepted only for the first ready
    lease, before any launch announcement or release, from the claim's device
    (lease token and session are checked by the caller). Every later lease,
    launch and release must match the rebound attempt. `attempt` is already
    normalized, so a legacy raw ID equals its prefixed form and is not a rebind.
    """
    if not attempt:
        return False
    if attempt == state.get("attempt", attempt):
        return True
    return all((f.get("phase") == "ready", not state.get("ready_id"),
                not state.get("launched"), not state.get("release_id"),
                bool(state.get("device")), f.get("device") == state.get("device")))


def advance_lease(state, comment, line, f):
    attempt = normalized_attempt(f.get("attempt_id"))
    if not all((line.startswith("DISPATCH_LEASE "), f.get("lease_token") == state["token"],
                f.get("session") == state["session"], lease_attempt_accepted(state, f, attempt))):
        return False
    state["attempt"] = attempt
    state["device_bound"] = state.get("device_bound", True) and bool(state.get("device")) \
        and f.get("device") == state["device"]
    if state.get("release_id"):
        valid = f.get("phase") == "terminal" and f.get("expires_at") == "0"
        if valid:
            state["terminal_id"] = comment["id"]
        return valid
    if f.get("phase") not in {"prelaunch", "ready"}:
        return False
    state.setdefault("expiries", []).append(f.get("expires_at", ""))
    if f["phase"] == "ready":
        state["ready_id"] = comment["id"]
    return True


def advance_release(state, comment, line, f):
    verdict = advance_never_ready_release(state, comment, line, f)
    return close_release(state, comment, f) if verdict is None else verdict


def advance_closed_claim(state, comment, line, f):
    """Require ready, release and terminal, or an exact never-ready claim-only, blocked or stale-reset release."""
    if comment["user"]["login"] != state["runner"]:
        return False
    if state.get("unbound_release_ids"):
        return line.startswith("CLAIM_RELEASED ") and f.get("reason") == CLAIM_ONLY \
            and close_claim_only(state, comment, f)
    if line.startswith("CLAIM_RELEASED "):
        return advance_release(state, comment, line, f)
    if line.startswith("Dispatching worker"):
        f = fields(comment["body"])
        state["launched"] = True
        return (not state.get("release_id") and f.get("lease_token") == state["token"]
                and f.get("session", state["session"]) == state["session"]
                and normalized_attempt(f.get("attempt_id", state.get("attempt"))) == state.get("attempt"))
    return advance_lease(state, comment, line, f)


def advance_history(state, comment, line, f, seen):
    if state is None:
        started = closed_claim(comment, line, f, seen)
        if started is None:
            return unattributed_release(comment, line, f)
        started["expiries"] = [f.get("expires_at", "")]
        started["device"] = f.get("device", "")
        return started
    return state if advance_closed_claim(state, comment, line, f) else None


def released_successor_history(comments, release_id, approval_id, released_lease, trusted_logins=()):
    """Preserve the history-or-None contract for existing acceptance callers."""
    history, _ = explain_released_successor_history(
        comments, release_id, approval_id, released_lease, trusted_logins)
    return history


def explain_released_successor_history(comments, release_id, approval_id, released_lease, trusted_logins=()):
    """Describe released history without enabling terminal-anomaly recovery."""
    return explain_reviewed_successor_history(
        comments, (release_id, approval_id), released_lease, {"trusted_logins": trusted_logins})


def explain_reviewed_successor_history(comments, bounds, released_lease, review):
    """Describe only fully closed, non-overlapping attempts preceding an approval.

    #aidevops:trust-boundary — historical closure needs explicit revision approval;
    elapsed time or a release message alone never grants continuation authority.
    Return (history, rejection context); diagnostics never affect acceptance.
    """
    release_id, approval_id = bounds
    trusted_logins = review.get("trusted_logins", ())
    history, state, episode_records = [], None, []
    seen = {released_lease[1]} if released_lease else set()
    for comment, line, f in events(comments, release_id, approval_id, trusted_logins):
        if not trusted(comment, trusted_logins):
            return None, (comment, line, state, "untrusted")
        if closes_released_attempt(released_lease, comment, line, f):
            continue
        episode_records.append((comment["id"], comment["created_at"],
                                comment["user"]["login"], comment["body"]))
        reconciled = acknowledged_terminal(state, (comment, line, f), review)
        if reconciled is not None:
            # Bind every observed episode record, including intermediate renewals;
            # publish only the fingerprint, never the underlying lease credentials.
            reconciled["evidence_sha256"] = hashlib.sha256(json.dumps(
                episode_records, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
            history.append(reconciled)
            state = None
            episode_records = []
            continue
        previous = state
        state = advance_history(state, comment, line, f, seen)
        if state is None:
            return None, (comment, line, previous, "transition_rejected")
        episode = completed_episode(state)
        if episode is not None:
            history.append(episode)
            state = None
            episode_records = []
    if state is not None:
        return None, (comment, line, state, "open_at_end")
    return history, None
