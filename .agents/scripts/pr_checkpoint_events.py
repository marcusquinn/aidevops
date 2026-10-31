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


def normalized_attempt(value):
    """Accept the launcher's raw ID without changing the attempt's identity."""
    if not isinstance(value, str) or not value or value == "attempt:":
        return ""
    return value if value.startswith("attempt:") else "attempt:" + value


def fields(line):
    pairs = re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line)
    parsed = dict(pairs)
    return parsed if len(parsed) == len(pairs) else {}


def author_trusted(comment, trusted_logins=()):
    #aidevops:trust-boundary — logins come only from authenticated repo permissions.
    elevated = {"CONTRIBUTOR", "NONE"} if comment.get("user", {}).get("login") in trusted_logins else set()
    return comment.get("author_association") in TRUSTED | elevated


def trusted(comment, trusted_logins=()):
    return all((author_trusted(comment, trusted_logins), bool(comment.get("user", {}).get("login")),
                comment.get("updated_at", comment.get("created_at")) == comment.get("created_at")))


def events(comments, start, end, trusted_logins=()):
    for comment in comments:
        # Edited trusted coordination must still invalidate a history, not vanish.
        if not start < comment["id"] < end or not author_trusted(comment, trusted_logins):
            continue
        for line in comment["body"].splitlines():
            if line.startswith(EVENTS):
                yield comment, line, fields(line)


def ready_leases(comments, approval, release, trusted_logins=()):
    ready = []
    for comment, line, f in events(comments, -1, release["id"], trusted_logins):
        if not trusted(comment, trusted_logins) or comment["user"]["login"] != release["user"]["login"]:
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
    return intervening_events_valid(between, release["user"]["login"], token,
                                    approval["attempt"], trusted_logins)


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


def checkpoint_release_fields(release, checkpoint_author):
    lines = [line for line in release["body"].splitlines() if line.startswith("CLAIM_RELEASED ")]
    released = fields(lines[0]) if len(lines) == 1 else {}
    reason = released.get("reason")
    poster = release["user"]["login"]
    #aidevops:trust-boundary — completed exits grant nothing by themselves. The
    # poster must authenticate their own ready lease, never the PR author's lease;
    # a blocked release must also be the checkpoint author's own.
    valid = all((reason in CHECKPOINT_RELEASE_REASONS, released.get("runner") == poster,
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
            claim = {**claim, **f}
        else:
            return False
    return not data.get("lease") or bool(claim and int(claim.get("expires_at", 0)) > now)
