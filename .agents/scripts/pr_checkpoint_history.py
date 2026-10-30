#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconstruct fully released historical attempts without granting ownership."""

from pr_checkpoint_events import closes_released_attempt, events, fields, normalized_attempt, trusted
from pr_checkpoint_never_ready import (CLAIM_ONLY, NEVER_READY_OUTCOMES,
                                       advance_never_ready_release, close_claim_only)


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
        if started is not None:
            started["expiries"] = [f.get("expires_at", "")]
            started["device"] = f.get("device", "")
        return started
    return state if advance_closed_claim(state, comment, line, f) else None


def completed_episode(state):
    if state.get("release_id") and not state.get("ready_id"):
        # Only the never-ready closers record a release without a ready lease.
        if state.get("outcome") not in NEVER_READY_OUTCOMES:
            raise ValueError("never-ready historical release has no recognised outcome")
        if not state["claim_id"] < state["release_id"] or any(
                not state["claim_id"] < diagnostic < state["release_id"]
                for diagnostic in state.get("unbound_release_ids", [])):
            raise ValueError("historical coordination ids are not strictly ordered")
        episode = {key: state[key] for key in ("runner", "claim_id", "release_id")}
        return {**episode, "outcome": state["outcome"],
                **({"unbound_release_ids": state["unbound_release_ids"]}
                   if state.get("unbound_release_ids") else {}),
                **({"attempt": state["attempt"]} if state.get("attempt") else {})}
    if not state.get("terminal_id"):
        return None
    if not (state["claim_id"] < state["ready_id"] < state["release_id"] < state["terminal_id"]):
        raise ValueError("historical coordination ids are not strictly ordered")
    return {key: state[key] for key in (
        "runner", "attempt", "claim_id", "ready_id", "release_id", "terminal_id")}


def released_successor_history(comments, release_id, approval_id, released_lease, trusted_logins=()):
    """Describe only fully closed, non-overlapping attempts preceding an approval.

    #aidevops:trust-boundary — historical closure needs explicit revision approval;
    elapsed time or a release message alone never grants continuation authority.
    """
    history, state = [], None
    seen = {released_lease[1]} if released_lease else set()
    for comment, line, f in events(comments, release_id, approval_id, trusted_logins):
        if not trusted(comment, trusted_logins):
            return None
        if closes_released_attempt(released_lease, comment, line, f):
            continue
        state = advance_history(state, comment, line, f, seen)
        if state is None:
            return None
        episode = completed_episode(state)
        if episode is not None:
            history.append(episode)
            state = None
    return history if state is None else None
