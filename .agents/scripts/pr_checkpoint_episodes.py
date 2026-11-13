#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate historical episode summaries without granting continuation authority."""

from pr_checkpoint_events import normalized_attempt, timestamp
from pr_checkpoint_never_ready import NEVER_READY_OUTCOMES
from pr_checkpoint_unattributed import UNATTRIBUTED

TERMINAL_WITHOUT_RELEASE = "terminal_without_release"


def positive_expiry(value):
    """Accept only positive ASCII decimal lease-expiry strings."""
    return isinstance(value, str) and value.isascii() and value.isdigit() and int(value) > 0


def acknowledged_terminal(state, event, review):
    """Record a reviewed historical anomaly, never synthesize a release.

    #aidevops:trust-boundary — only explicit exact-ID revision approval may
    reconcile this shape. A terminal record or elapsed lease alone grants nothing.
    """
    comment, line, f = event
    if state is None or comment["id"] not in review.get("terminal_ids", ()):
        return None
    expiries = state.get("expiries", [])
    valid_expiries = bool(expiries) and all(positive_expiry(value) for value in expiries)
    if not all((line.startswith("DISPATCH_LEASE "), not state.get("release_id"),
                not state.get("unbound_release_ids"), bool(state.get("ready_id")),
                comment["user"]["login"] == state["runner"],
                f.get("phase") == "terminal", f.get("expires_at") == "0",
                f.get("lease_token") == state["token"], f.get("session") == state["session"],
                normalized_attempt(f.get("attempt_id")) == state.get("attempt"),
                bool(state.get("device")), state.get("device_bound", False),
                f.get("device") == state.get("device"), valid_expiries)):
        return None
    before = review.get("before", 0)
    if max(int(value) for value in expiries) >= before or timestamp(comment["created_at"]) > before:
        return None
    if not state["claim_id"] < state["ready_id"] < comment["id"]:
        return None
    episode = {key: state[key] for key in ("runner", "attempt", "claim_id", "ready_id")}
    return {**episode, "terminal_id": comment["id"], "outcome": TERMINAL_WITHOUT_RELEASE,
            "release_provenance": "missing", "execution_status": "unrecovered"}


EXPIRED_RELEASE_GRACE_SECONDS = 3600


def released_without_terminal(state, review):
    """Accept a released episode whose owning device never posted its terminal lease.

    #aidevops:trust-boundary — GH#38103: only the owning device can close its
    lease, so another machine's released episode would otherwise block approval
    forever. The episode needs a ready lease, a release from its own runner, every
    lease expired more than 60 minutes before approval time, and an
    executor-less attestation naming the exact release comment. Liveness is
    local machine state, so the template caller supplies the attestation and the
    approval binds it; the release reason becomes the recorded outcome.
    """
    if state is None or state.get("terminal_id") or state.get("unbound_release_ids"):
        return None
    release_id, ready_id, reason = state.get("release_id"), state.get("ready_id"), state.get("release_reason")
    expiries = state.get("expiries", [])
    if not (release_id and ready_id and reason and expiries and
            all(positive_expiry(value) for value in expiries) and
            release_id in review.get("executorless_release_ids", ()) and
            state["claim_id"] < ready_id < release_id):
        return None
    if max(int(value) for value in expiries) + EXPIRED_RELEASE_GRACE_SECONDS >= review.get("before", 0):
        return None
    episode = {key: state[key] for key in ("runner", "attempt", "claim_id", "ready_id", "release_id")}
    return {**episode, "outcome": reason}


def completed_episode(state):
    """Summarize a normally closed episode, preserving its ordered evidence IDs."""
    if state.get("outcome") == UNATTRIBUTED:
        return dict(state)
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
