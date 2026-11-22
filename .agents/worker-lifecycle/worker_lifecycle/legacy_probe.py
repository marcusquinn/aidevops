"""Journal receipts and host-probe records for temporary legacy cleanup.

Receipts use the existing event journal; no new tables. Remove with legacy_cleanup.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
from uuid import UUID, uuid4, uuid5

from .legacy_discovery import same_tree
from .retirement import _git


def event_id(operation, phase):
    """Return the deterministic event ID for an operation phase."""
    return str(uuid5(UUID(operation), "legacy-" + phase))


def operation_id(store, path):
    """Return the deterministic operation ID for a legacy path."""
    return str(uuid5(UUID(store.installation_id()), "legacy-cleanup:" + path))


def receipt(connection, operation, phase):
    """Return the recorded payload for an operation phase, or None."""
    row = connection.execute("SELECT payload FROM events WHERE event_id=?",
                             (event_id(operation, phase),)).fetchone()
    return json.loads(row[0]) if row else None


def checkpoint(store, connection, operation, phase, payload):
    """Persist before destructive steps, then reacquire the admission writer lock."""
    store._event(connection, event_id(operation, phase), payload)
    connection.commit()
    connection.execute("BEGIN IMMEDIATE")


def host_probe(store):
    """Return the stable per-host reconstructible probe operation id."""
    return str(uuid5(UUID(store.installation_id()),
                     "reconstructible-host-probe:" + socket.gethostname()))


def latest_probe_plan(connection, host):
    """Return the newest journaled host probe plan payload, or None."""
    row = connection.execute(
        "SELECT payload FROM events WHERE json_extract(payload,'$.type')=? "
        "AND json_extract(payload,'$.host')=? ORDER BY sequence DESC LIMIT 1",
        ("reconstructible-host-probe-plan", host),
    ).fetchone()
    if not row:
        return None
    plan = json.loads(row[0])
    if not isinstance(plan.get("plan"), dict) or receipt(connection, plan["attempt"], "cancelled"):
        return None
    return plan


def interrupted_probe(store, connection, item):
    """True when this absent source is an unverified, unretired host probe."""
    host = host_probe(store)
    previous = latest_probe_plan(connection, host)
    return bool(
        previous and previous["plan"]["source"] == item["path"]
        and (receipt(connection, host, "verified") is None
             or receipt(connection, operation_id(store, item["path"]), "retired") is None))


def record_probe_recovery(store, connection, host, original):
    """Write missing recovery receipts, retired first so a failure stays retryable."""
    operation = operation_id(store, original["source"])
    if receipt(connection, operation, "retired") is None:
        checkpoint(store, connection, operation, "retired",
                   dict(original, type="reconstructible-worktree-retired",
                        branch_preserved=True))
    if receipt(connection, host, "verified") is None:
        checkpoint(store, connection, host, "verified",
                    dict(original, type="reconstructible-host-probe-verified"))


def prepare_reconstructible_probe(store, connection, host, plan, verify):
    """Recover or cancel the previous attempt before starting a new probe."""
    previous = latest_probe_plan(connection, host)
    if receipt(connection, host, "verified") is not None:
        if plan is None and previous and not os.path.lexists(previous["plan"]["source"]):
            record_probe_recovery(store, connection, host, previous["plan"])
        return False
    if previous:
        original = previous["plan"]
        if not os.path.lexists(original["source"]):
            try:
                verify(original, probe=True)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                raise ValueError("reconstructible-probe-verification-pending") from error
            record_probe_recovery(store, connection, host, original)
            return False
        same_tree(Path(original["source"]), original)
        checkpoint(store, connection, previous["attempt"], "cancelled",
                   {"type": "reconstructible-host-probe-cancelled", "host": host})
    if plan is None:
        return False
    attempt = str(uuid4())
    checkpoint(store, connection, attempt, "plan",
               {"type": "reconstructible-host-probe-plan", "host": host,
                "attempt": attempt, "plan": plan})
    return True


def verify_reconstructible(plan, *, probe):
    """Verify the removed source can be reconstructed from retained Git objects."""
    if os.path.lexists(plan["source"]):
        raise ValueError("reconstructible-source-still-present")
    common, head, branch = plan["common"], plan["head"], plan["branch"]
    _git("--git-dir", common, "cat-file", "-e", head + "^{commit}")
    if branch != "HEAD" and _git("--git-dir", common, "rev-parse", branch) != head:
        raise ValueError("reconstructible-branch-changed")
    if probe:
        # A fresh disposable checkout proves restoration without touching the branch.
        parent = Path(tempfile.mkdtemp(prefix=".reconstructible-probe-",
                                      dir=Path(plan["source"]).parent))
        target = str(parent / "tree")
        _git("--git-dir", common, "worktree", "add", "--detach", target, head)
        if _git("-C", target, "rev-parse", "HEAD") != head:
            raise ValueError("reconstructible-restore-mismatch")
        _git("--git-dir", common, "worktree", "remove", target)
        parent.rmdir()
