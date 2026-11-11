# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Recognize sequential approval-bound attempts whose runtime never launched."""

from pr_checkpoint_events import EVENTS, events, fields, trusted

NOT_LAUNCHED_REASON = "worker_not_launched"
# Bound reuse so a persistent prelaunch fault cannot redispatch indefinitely.
MAX_NOT_LAUNCHED_REUSES = 3
LEASE_FIELD = "lease_token"


def single_event(comment):
    return sum(1 for line in comment["body"].splitlines() if line.startswith(EVENTS)) == 1


def not_launched_claim(data, approval_id, comment, line, f):
    lease = f.get(LEASE_FIELD)
    if not all((line.startswith("DISPATCH_CLAIM "), bool(lease), lease != data.get("lease"),
                f.get("nonce") == lease, f.get("checkpoint_mode", "revision") == "revision",
                f.get("checkpoint_approval") == str(approval_id),
                f.get("runner") == comment["user"]["login"], bool(f.get("session")))):
        return None
    return {"runner": f["runner"], "lease": lease, "session": f["session"], "ids": [comment["id"]]}


def not_launched_step(episode, comment, line, f):
    """Return 'open', 'released' or None for one event of an approved attempt."""
    if comment["user"]["login"] != episode["runner"]:
        return None
    if line.startswith("CLAIM_RELEASED "):
        bound = all((f.get("reason") == NOT_LAUNCHED_REASON, f.get("runner") == episode["runner"],
                     f.get(LEASE_FIELD) == episode["lease"]))
        return "released" if bound else None
    if line.startswith("Dispatching worker"):
        return "open" if fields(comment["body"]).get(LEASE_FIELD) == episode["lease"] else None
    bound = all((line.startswith("DISPATCH_LEASE "), f.get(LEASE_FIELD) == episode["lease"],
                 f.get("session") == episode["session"], f.get("phase") in {"prelaunch", "ready"}))
    return "open" if bound else None


def closes_not_launched(closed, comment, line, f):
    return any(all((line.startswith("DISPATCH_LEASE "), f.get("phase") == "terminal",
                    f.get(LEASE_FIELD) == lease, comment["user"]["login"] == runner))
               for runner, lease in closed)


class NotLaunchedReuse:
    """Collect closed episodes while leaving invalid or interleaved events visible."""

    def __init__(self):
        self.skipped = set()
        self.closed = []
        self.episode = None

    def advance(self, comment, line, f, usable):
        step = not_launched_step(self.episode, comment, line, f) if usable else None
        if step is None:
            # Leave the interleaved episode visible; successors_valid rejects it.
            self.episode = None
            return
        self.episode["ids"].append(comment["id"])
        if step == "released":
            self.skipped.update(self.episode["ids"])
            self.closed.append((self.episode["runner"], self.episode["lease"]))
            self.episode = None

    def consume(self, data, approval_id, comment, line, f):
        usable = trusted(comment, data.get("trusted_logins", ())) and single_event(comment)
        if usable and closes_not_launched(self.closed, comment, line, f):
            self.skipped.add(comment["id"])
        elif self.episode is None:
            self.episode = not_launched_claim(data, approval_id, comment, line, f) if usable else None
        else:
            self.advance(comment, line, f, usable)


def not_launched_reuse_ids(data, comments, approval_id):
    """Comment IDs of closed approved attempts whose runtime never launched.

    #aidevops:trust-boundary — GH#37669: a revision attempt that released
    `worker_not_launched` changed nothing on the approved exact head, so the
    approval stays reusable for that head. Only a sequential, unedited episode
    by one trusted runner (claim bound to this approval, its own leases or
    launch notice, its own not-launched release, then its own terminal lease)
    is skipped. Any other or interleaved event keeps fencing the approval.
    Returns None when more than MAX_NOT_LAUNCHED_REUSES episodes exist.
    """
    state = NotLaunchedReuse()
    for comment, line, f in events(comments, approval_id, float("inf"), data.get("trusted_logins", ())):
        state.consume(data, approval_id, comment, line, f)
    return None if len(state.closed) > MAX_NOT_LAUNCHED_REUSES else state.skipped
