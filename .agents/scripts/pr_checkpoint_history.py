#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reconstruct fully released historical attempts without granting ownership."""

from pr_checkpoint_events import closes_released_attempt, events, fields, trusted


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
    if f["phase"] == "ready":
        state["ready_id"] = comment["id"]
    return True


def advance_closed_claim(state, comment, line, f):
    """Require a matching ready lease, release and terminal before considering closure."""
    if comment["user"]["login"] != state["runner"]:
        return False
    if line.startswith("CLAIM_RELEASED "):
        return close_release(state, comment, f)
    if line.startswith("Dispatching worker"):
        f = fields(comment["body"])
        return (not state.get("release_id") and f.get("lease_token") == state["token"]
                and f.get("session", state["session"]) == state["session"]
                and f.get("attempt_id", state.get("attempt")) == state.get("attempt"))
    return advance_lease(state, comment, line, f)


def advance_history(state, comment, line, f, seen):
    if state is None:
        return closed_claim(comment, line, f, seen)
    return state if advance_closed_claim(state, comment, line, f) else None


def completed_episode(state):
    if not state.get("terminal_id"):
        return None
    if not (state["claim_id"] < state["ready_id"] < state["release_id"] < state["terminal_id"]):
        raise ValueError("historical coordination ids are not strictly ordered")
    return {key: state[key] for key in (
        "runner", "attempt", "claim_id", "ready_id", "release_id", "terminal_id")}


def released_successor_history(comments, release_id, approval_id, released_lease):
    """Describe only fully closed, non-overlapping attempts preceding an approval.

    #aidevops:trust-boundary — historical closure needs explicit revision approval;
    elapsed time or a release message alone never grants continuation authority.
    """
    history, state = [], None
    seen = {released_lease[1]} if released_lease else set()
    for comment, line, f in events(comments, release_id, approval_id):
        if not trusted(comment):
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
