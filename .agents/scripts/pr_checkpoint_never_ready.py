#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Close historical claims that never reached a ready lease (GH#35331/35683/36005).

Every closer here reports an explicit successor the approval must acknowledge;
none grants continuation by itself.
"""

import re

from pr_checkpoint_events import timestamp


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


STALE_RESET = "stale_assignment_reset"
STALE_RESET_BEFORE_READY = "stale_reset_before_ready"


def close_stale_reset_before_ready(state, comment, f):
    """GH#36005: the claim owner's own stale-recovery release closes a never-ready claim.

    #aidevops:trust-boundary — every close_blocked_before_ready guard applies
    (trusted unedited comment by the claim's runner, nothing else in between,
    identity fields bound to the claim, every expiry known and elapsed, no ready
    lease, launch or prior release). Stale-recovery lines always carry the runner
    device, so the device is mandatory and must equal the claim's device. The
    episode is an explicit successor the approval must acknowledge; it grants
    nothing by itself.
    """
    if not state.get("device") or f.get("device") != state["device"]:
        return False
    if not close_blocked_before_ready(state, comment, f):
        return False
    state["outcome"] = STALE_RESET_BEFORE_READY
    return True


_PRE_READY_CLOSERS = {
    "worker_ownership_lost": acknowledge_unbound_release,
    "blocked": lambda state, comment, _line, f: close_blocked_before_ready(state, comment, f),
    STALE_RESET: lambda state, comment, _line, f: close_stale_reset_before_ready(state, comment, f),
}


def advance_never_ready_release(state, comment, line, f):
    """Return a never-ready closer's verdict, or None when no closer applies.

    Claim-only closure checks its own ready guard; the other closers apply only
    before a ready lease, after which the normal ready/release path decides.
    """
    reason = f.get("reason")
    if reason == CLAIM_ONLY:
        return close_claim_only(state, comment, f)
    closer = None if state.get("ready_id") else _PRE_READY_CLOSERS.get(reason)
    return closer(state, comment, line, f) if closer else None


NEVER_READY_OUTCOMES = frozenset({CLAIM_ONLY, BLOCKED_BEFORE_READY, STALE_RESET_BEFORE_READY})
