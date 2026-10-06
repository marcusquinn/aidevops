# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded recovery predicates and read-only REST admission diagnostics."""

import json
import os
import time

from gh_transport_identity import credentials_share_proven_owner
from gh_transport_status import LIVE_WINDOWS, admission_status

__all__ = ["LIVE_WINDOWS", "admission_status"]

MAX_RESERVATION_AGE = 180  # 90s native timeout, bounded cleanup and admission margin.


def mark_dead_reservations(budget, now, process_birth):
    """Dead or over-age executors retain uncertain spend, not probe ownership.

    uncertain=2 denotes an expired but live executor: it may resume and spend
    after a newer observation, so finish() must not clear its debt as completed
    uncertain=1 work. Recheck liveness until it finishes or becomes dead.
    """
    for identity, pid, birth, started in budget.db.execute(
        "SELECT id,pid,birth,started FROM reservation WHERE scope=? AND uncertain IN (0,2)",
        (budget.scope,),
    ).fetchall():
        try:
            os.kill(pid, 0)
            current_birth = budget.birth if pid == os.getpid() else process_birth(pid)
            if birth and current_birth and birth != current_birth:
                raise ProcessLookupError
        except ProcessLookupError:
            budget.db.execute("UPDATE reservation SET uncertain=1,started=? WHERE id=?",
                              (now, identity))
        else:
            if now - started >= MAX_RESERVATION_AGE:
                budget.db.execute("UPDATE reservation SET uncertain=2 WHERE id=?", (identity,))


def reserve_probe_allowed(row, active, total, previous, now):
    if active or row[0] - total < 1:
        return False
    last_probe = previous[0] if previous else row[2]
    return now - last_probe >= 60


def revalidation_wait(budget, resource, row, active, now):
    """Persist cadence independently of response freshness; drain before probing.

    Reuses the existing schema. An empty reservation ID is only a cadence anchor,
    never a grant; older readers remain conservative and cannot recover through it.
    """
    if not row or row[1] <= now:
        return False
    budget.db.execute("INSERT OR IGNORE INTO revalidation VALUES(?,?,?,?)",
                      (budget.scope, resource, row[2], ""))
    previous = budget.db.execute(
        "SELECT started,reservation_id FROM revalidation WHERE scope=? AND resource=?",
        (budget.scope, resource),
    ).fetchone()
    probe_active = budget.db.execute(
        "SELECT 1 FROM reservation WHERE id=? AND scope=? AND resource=? AND uncertain=0",
        (previous[1], budget.scope, resource),
    ).fetchone()
    return bool(probe_active or (active and now - previous[0] >= 60))


def record_budget_transition(budget, previous, incoming, accepted, recovered, ordered,
                             *, event="response_observation"):
    """Opt-in numeric evidence only: never headers, endpoints or identities."""
    if os.environ.get("AIDEVOPS_GH_BUDGET_DIAGNOSTICS") != "1":
        return
    record = json.dumps({
        "event": event, "previous": previous, "observed_at": time.time(),
        "incoming": incoming, "accepted": accepted, "probe_recovered": recovered,
        "causally_newer": ordered,
        "reason": ("newer_window" if recovered and previous and incoming["reset"] > previous["reset"]
                   else "serialized_probe" if recovered else "conservative_observation"),
    }, sort_keys=True)
    try:
        fd = os.open(budget.path.parent / "budget-transitions.jsonl",
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as stream:
            if os.fstat(stream.fileno()).st_uid != os.getuid():
                return
            os.fchmod(stream.fileno(), 0o600)
            print(record, file=stream)
    except OSError:
        # Optional evidence must never change admission or contaminate CLI JSON.
        return


def probe_recovers(budget, reservation, resource, row, reset_at):
    """Accept bound rollover or serialized probe evidence without changing ownership."""
    if not row:
        return False
    probe = budget.db.execute(
        "SELECT reservation_id FROM revalidation WHERE scope=? AND resource=?",
        (budget.scope, resource),
    ).fetchone()
    own = budget.db.execute(
        "SELECT started,credential FROM reservation WHERE id=? AND scope=? AND resource=?",
        (reservation, budget.scope, resource),
    ).fetchone()
    if not own or own[1] != budget.credential:
        return False
    bound = bound_credentials(budget)
    owners = len(bound)
    # One allowance: a single bound credential, a configured owner, or every
    # bound credential proven to belong to one login (digest only). Different
    # or unproven owners never inherit each other's balance.
    one_allowance = (owners == 1 or budget.attributed
                     or credentials_share_proven_owner(budget.path.parent, bound))
    # A later reset identifies a new window for the one allowance, even
    # before the stale local reset expires. Shared owners still need a probe.
    if one_allowance and reset_at > row[1]:
        return True
    if not probe or reservation != probe[0]:
        return False
    return one_allowance and own[0] >= row[2] and reset_at >= row[1]


def note_live_window(budget, resource, reset_at, now):
    """Remember a later reset which was observed but not accepted (numbers only)."""
    path = budget.path.parent / LIVE_WINDOWS
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
        if not isinstance(data, dict):
            data = {}
        key = f"{budget.scope}:{resource}"
        if int(data.get(key, {}).get("reset", 0)) >= reset_at:
            return
        data[key] = {"reset": reset_at, "observed": now}
        temporary = path.with_name(f"{LIVE_WINDOWS}.{os.getpid()}.tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, sort_keys=True)
        os.replace(temporary, path)
    except (OSError, ValueError, AttributeError):
        return


def bound_credentials(budget) -> list:
    return [credential for credential, scope in
            budget.db.execute("SELECT credential,scope FROM binding").fetchall()
            if budget._root(scope) == budget.scope]
