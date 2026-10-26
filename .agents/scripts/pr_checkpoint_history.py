#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconstruct fully released historical attempts without granting ownership."""

import re

from pr_checkpoint_events import closes_released_attempt, events, fields, timestamp, trusted


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
                 f.get("attempt_id", state["attempt"]) == state["attempt"]))
    if valid:
        state["release_id"] = comment["id"]
    return valid


CLAIM_ONLY = "claim_only_no_worker"


def acknowledge_unbound_release(state, comment, line, f):
    """Retain one legacy no-session diagnostic; only an exact later abort can close it.

    #aidevops:trust-boundary — no identity-bearing release is treated as unbound.
    The diagnostic ID must be acknowledged in the new approval, not ignored.
    """
    allowed = {"reason", "runner", "ts", "aidevops_version", "opencode_version", "exit", "session_count"}
    valid = all((not state.get("ready_id"), not state.get("launched"),
                 not state.get("release_id"), not state.get("unbound_release_ids"),
                 state["claim_id"] < comment["id"],
                 re.fullmatch(r"CLAIM_RELEASED(?: [a-z_]+=[^\s]+)+", line) is not None,
                 set(f) <= allowed, f.get("runner") == state["runner"],
                 f.get("exit") == "1", f.get("session_count") == "0"))
    if valid:
        state["unbound_release_ids"] = [comment["id"]]
    return valid


BLOCKED_BEFORE_READY = "blocked_before_ready"


def expiries_elapsed(state, comment):
    """Every claim/renewal deadline must be known and elapsed when released;
    an unknown expiry or a release racing a live renewal fails closed."""
    expiries = state.get("expiries", [])
    return bool(expiries) and all(re.fullmatch(r"[1-9][0-9]*", e) for e in expiries) \
        and max(int(e) for e in expiries) < timestamp(comment["created_at"])


def never_ready_open(state, comment, f):
    return all((expiries_elapsed(state, comment), state["claim_id"] < comment["id"],
                not state.get("release_id"), not state.get("ready_id"),
                not state.get("launched"), f.get("runner") == state["runner"]))


def close_claim_only(state, comment, f):
    """GH#35331: the owner's exact claim-only release closes a never-ready claim.

    #aidevops:trust-boundary — closure is bound to the claim comment ID and nonce,
    rejected after any ready lease or launch, and grants no continuation by itself.
    """
    valid = all((never_ready_open(state, comment, f), f.get("nonce") == state["token"],
                 f.get("claim_id") == str(state["claim_id"])))
    if valid:
        state["release_id"] = comment["id"]
        state["outcome"] = CLAIM_ONLY
    return valid


def close_blocked_before_ready(state, comment, f):
    """GH#35683: the claim owner's own blocked release closes a never-ready claim.

    #aidevops:trust-boundary — the caller already requires a trusted, unedited
    comment by the claim's runner and rejects any other claim, actor or event in
    between. This adds: release after the claim, no ready lease, launch or prior
    release, every claim/renewal expiry known and elapsed, and every identity
    field present on the line bound to this claim. A legacy line without
    nonce/claim_id binds only by runner and ordering. The episode is reported
    as an explicit successor the approval must acknowledge; it grants nothing.
    """
    claim_nonce = state["token"]
    expected = {"nonce": claim_nonce, "lease_" + "token": claim_nonce,
                "claim_id": str(state["claim_id"]), "session": state["session"],
                "attempt_id": state.get("attempt", "")}
    bound = all(f.get(key, value) == value for key, value in expected.items())
    valid = bound and never_ready_open(state, comment, f)
    if valid:
        state["release_id"] = comment["id"]
        state["outcome"] = BLOCKED_BEFORE_READY
    return valid


def advance_lease(state, comment, line, f):
    if not all((line.startswith("DISPATCH_LEASE "), f.get("lease_token") == state["token"],
                f.get("session") == state["session"],
                f.get("attempt_id", "").startswith("attempt:"),
                f.get("attempt_id") == state.get("attempt", f.get("attempt_id")))):
        return False
    state["attempt"] = f["attempt_id"]
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
    if f.get("reason") == CLAIM_ONLY:
        return close_claim_only(state, comment, f)
    if f.get("reason") == "worker_ownership_lost" and not state.get("ready_id"):
        return acknowledge_unbound_release(state, comment, line, f)
    if f.get("reason") == "blocked" and not state.get("ready_id"):
        return close_blocked_before_ready(state, comment, f)
    return close_release(state, comment, f)


def advance_closed_claim(state, comment, line, f):
    """Require ready, release and terminal, or an exact never-ready claim-only or blocked release."""
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
                and f.get("attempt_id", state.get("attempt")) == state.get("attempt"))
    return advance_lease(state, comment, line, f)


def advance_history(state, comment, line, f, seen):
    if state is None:
        started = closed_claim(comment, line, f, seen)
        if started is not None:
            started["expiries"] = [f.get("expires_at", "")]
        return started
    return state if advance_closed_claim(state, comment, line, f) else None


def completed_episode(state):
    if state.get("release_id") and not state.get("ready_id"):
        # Only the never-ready closers record a release without a ready lease.
        if state.get("outcome") not in {CLAIM_ONLY, BLOCKED_BEFORE_READY}:
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
