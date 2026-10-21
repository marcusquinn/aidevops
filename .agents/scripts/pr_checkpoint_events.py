#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure authenticated coordination-event predicates for checkpoint recovery."""

import datetime as dt
import re

TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
EVENTS = ("DISPATCH_CLAIM ", "DISPATCH_LEASE ", "CLAIM_RELEASED ",
          "Dispatching worker", "Interactive session claimed")


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def fields(line):
    pairs = re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line)
    parsed = dict(pairs)
    return parsed if len(parsed) == len(pairs) else {}


def trusted(comment):
    return (comment.get("author_association") in TRUSTED
            and bool(comment.get("user", {}).get("login"))
            and comment.get("updated_at", comment.get("created_at")) == comment.get("created_at"))


def events(comments, start, end):
    for comment in comments:
        if not start < comment["id"] < end or comment.get("author_association") not in TRUSTED:
            continue
        for line in comment["body"].splitlines():
            if line.startswith(EVENTS):
                yield comment, line, fields(line)


def ready_leases(comments, approval, release):
    ready = []
    for comment, line, f in events(comments, -1, release["id"]):
        if not trusted(comment) or comment["user"]["login"] != approval["runner"]:
            continue
        if (line.startswith("DISPATCH_LEASE ") and f.get("attempt_id") == approval["attempt"]
                and f.get("phase") == "ready"):
            ready.append((comment["id"], f))
    return ready


def original_lease(comments, approval, release, released):
    ready = ready_leases(comments, approval, release)
    tokens = {f.get("lease_token") for _, f in ready}
    if len(tokens) != 1 or not next(iter(tokens)):
        return False
    token = next(iter(tokens))
    if released.get("lease_token", token) != token:
        return False
    between = events(comments, ready[-1][0], release["id"])
    return intervening_events_valid(between, approval["runner"], token)


def intervening_events_valid(between, runner, token):
    # Even a legacy release cannot terminate another attempt that intervened
    # after the approved attempt's ready lease.
    for comment, line, f in between:
        if line.startswith("Dispatching worker"):
            f = fields(comment["body"])
        if (not trusted(comment) or comment["user"]["login"] != runner
                or f.get("lease_token") != token or line.startswith("DISPATCH_CLAIM ")):
            return False
    return True


def blocked_release_fields(release, runner):
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    if len(lines) != 1:
        return None
    released = fields(lines[0])
    if released.get("reason") != "blocked" or released.get("runner") != runner:
        return None
    return released


def release_for(comments, approval, approval_comment):
    matches = [c for c in comments if c["id"] == approval.get("release_id")]
    if len(matches) != 1:
        return None
    release = matches[0]
    identity_valid = all((trusted(release), release["user"]["login"] == approval["runner"],
                          release["id"] < approval_comment["id"]))
    released = blocked_release_fields(release, approval["runner"])
    if not identity_valid or released is None:
        return None
    return release if original_lease(comments, approval, release, released) else None


def own_claim_matches(data, approval_id, comment, line, f):
    expected = {"nonce": data.get("lease"), "lease_token": data.get("lease"),
                "checkpoint_approval": str(approval_id), "session": data.get("session"),
                "runner": data.get("assignee")}
    return all((bool(data.get("lease")), line.startswith("DISPATCH_CLAIM "),
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


def released_attempt_token(comments, approval, release):
    tokens = {f.get("lease_token") for _, f in ready_leases(comments, approval, release)}
    return next(iter(tokens)) if len(tokens) == 1 else None


def closes_released_attempt(released_lease, comment, line, f):
    # GH#33839: the released attempt closes its own lease after CLAIM_RELEASED;
    # that terminal lease ends the old attempt and is not a successor owner.
    runner, token = released_lease or (None, None)
    return all((bool(token), line.startswith("DISPATCH_LEASE "), f.get("phase") == "terminal",
                f.get("lease_token") == token, comment["user"]["login"] == runner))


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


def advance_closed_claim(state, comment, line, f):
    """Require a matching ready lease, release and terminal before considering closure."""
    if comment["user"]["login"] != state["runner"]:
        return False
    if line.startswith("CLAIM_RELEASED "):
        if not state.get("attempt") or not state.get("ready_id"):
            return False
        if not all((not state.get("release_id"), bool(f.get("reason")),
                    f.get("runner") == state["runner"],
                    f.get("lease_token", state["token"]) == state["token"],
                    f.get("attempt_id", state["attempt"]) == state["attempt"])):
            return False
        state["release_id"] = comment["id"]
        return True
    if line.startswith("Dispatching worker"):
        f = fields(comment["body"])
        return (not state.get("release_id") and f.get("lease_token") == state["token"]
                and f.get("session", state["session"]) == state["session"]
                and f.get("attempt_id", state.get("attempt")) == state.get("attempt"))
    if not all((line.startswith("DISPATCH_LEASE "), f.get("lease_token") == state["token"],
                f.get("session") == state["session"],
                f.get("attempt_id", "").startswith("attempt:"),
                f.get("attempt_id") == state.get("attempt", f.get("attempt_id")))):
        return False
    state["attempt"] = f["attempt_id"]
    if state.get("release_id"):
        if f.get("phase") != "terminal" or f.get("expires_at") != "0":
            return False
        state["terminal_id"] = comment["id"]
        return True
    if f.get("phase") not in {"prelaunch", "ready"}:
        return False
    if f["phase"] == "ready":
        state["ready_id"] = comment["id"]
    return True


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
        if state is None:
            state = closed_claim(comment, line, f, seen)
            if state is None:
                return None
        elif not advance_closed_claim(state, comment, line, f):
            return None
        if state.get("terminal_id"):
            if not (state["claim_id"] < state["ready_id"] < state["release_id"] < state["terminal_id"]):
                return None
            history.append({key: state[key] for key in (
                "runner", "attempt", "claim_id", "ready_id", "release_id", "terminal_id")})
            state = None
    return history if state is None else None


def successors_valid(data, comments, release_id, approval_id, now):
    history = released_successor_history(comments, release_id, approval_id, data.get("released_lease"))
    if history is None or history != data.get("released_successors", []):
        return False
    historical_claims = {item["claim_id"] for item in history}
    used_tokens = {f.get("lease_token") for c, _, f in events(comments, release_id, approval_id)
                   if c["id"] in historical_claims}
    used_tokens.add((data.get("released_lease") or (None, None))[1])
    if data.get("lease") and data["lease"] in used_tokens:
        return False
    claim = None
    for comment, line, f in events(comments, release_id, float("inf")):
        if not trusted(comment):
            return False
        if comment["id"] < approval_id:
            continue
        if closes_released_attempt(data.get("released_lease"), comment, line, f):
            continue
        if claim is None and own_claim_matches(data, approval_id, comment, line, f):
            claim = f
        elif own_renewal_matches(claim, comment, line, f):
            claim = {**claim, **f}
        else:
            return False
    return not data.get("lease") or bool(claim and int(claim.get("expires_at", 0)) > now)
